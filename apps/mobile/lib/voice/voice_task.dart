import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:hey_overlay/hey_overlay.dart' as ho;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../data/note.dart';
import '../data/notes_db.dart';
import '../data/settings.dart';
import '../util/text.dart';
import 'cloud.dart';
import 'model_files.dart';
import 'voice_engine.dart';
import 'whisper.dart';

/// Messages between the UI and the background voice service.
abstract final class Msg {
  // UI -> service
  static const start = 'start';
  static const stop = 'stop';
  static const cancel = 'cancel';
  static const reload = 'reload';
  static const ping = 'ping';

  // service -> UI
  static const state = 'state';
  static const partial = 'partial';
  static const saved = 'saved';
  static const nothing = 'nothing';
  static const error = 'error';

  /// One diagnostics line: {'type': log, 'line': ..., 'status': ...?}.
  static const log = 'log';

  /// Saved with FlutterForegroundTask.saveData so a capture requested before
  /// the service finished starting isn't lost.
  static const pendingStartKey = 'pendingStart';
}

/// Entry point of the foreground service's isolate.
@pragma('vm:entry-point')
void startVoiceTask() {
  // This isolate has its own Flutter binding; plugins (record, audioplayers)
  // need it before their first platform-channel call.
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(VoiceTaskHandler());
}

/// Runs inside the Android foreground service: owns the microphone, runs the
/// [VoiceEngine] and saves notes to the local database.
class VoiceTaskHandler extends TaskHandler {
  // Created on first use (in onStart), never at construction: the
  // background isolate's binding must exist before plugins touch channels.
  late final _recorder = AudioRecorder();
  late final _player = AudioPlayer();
  StreamSubscription<Uint8List>? _mic;
  VoiceEngine? _engine;
  WhisperWorker? _whisper;
  final _cloud = CloudTranscriber();

  /// Which engine produced the last transcript, for the log and the UI.
  String _lastEngine = 'streaming';
  Future<void>? _whisperStarting;
  late NotesDb _db;
  late AppSettings _settings;
  int? _carry;
  DateTime _lastPartialSent = DateTime(0);
  String _partial = '';
  double _level = 0;
  bool _userCancelled = false;

  /// The over-other-apps bubble is showing for the current capture.
  bool _overlayOn = false;
  Timer? _overlayHide;

  /// A start request that arrived while the models were still loading.
  bool _pendingStart = false;
  int _pcmChunks = 0;
  bool _acceptFailed = false;

  // Mic watchdog, every 10 s (onRepeatEvent). No audio, or pure digital
  // silence (peak exactly 0; a real quiet room still has noise) while
  // waiting for the wake word, means the stream is stuck or muted: restart
  // it. A summary is logged every 30 s.
  int _healthChunks = 0;
  int _healthPeak = 0;
  int _silentChecks = 0;
  int _healthTicks = 0;
  DateTime _lastRestart = DateTime(0);
  bool _warnedMuted = false;
  bool _restartingMic = false;

  /// Sends a diagnostics line to the UI (Settings → Diagnostics). [status]
  /// is a short user-facing state shown while waiting to capture.
  void _log(String line, {String? status, bool error = false}) {
    FlutterForegroundTask.sendDataToMain({
      'type': Msg.log,
      'line': line,
      'status': ?status,
      'error': error,
    });
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    var step = 'starting';
    final sw = Stopwatch()..start();
    try {
      _log(
        'service started (${starter.name})',
        status: 'Starting voice engine…',
      );
      step = 'loading speech library';
      so.initBindings();
      step = 'reading settings';
      _settings = await AppSettings.load();
      step = 'opening database';
      _db = await NotesDb.open();
      step = 'unpacking models';
      final paths = await ModelFiles.ensureBundled();
      _pendingStart |=
          await FlutterForegroundTask.getData<bool>(key: Msg.pendingStartKey) ??
          false;
      await FlutterForegroundTask.removeData(key: Msg.pendingStartKey);

      step = 'loading speech models';
      _log(
        'loading models (whisper: ${paths.whisperReady ? 'yes' : 'no'})',
        status: 'Loading speech models…',
      );
      final engine = VoiceEngine(paths)
        ..wakeEnabled = _settings.wakeEnabled
        ..silenceSecs = _settings.silenceSecs;
      // Whisper runs on its own isolate (see _startWhisper), not in here.
      engine.init(sensitivity: _settings.sensitivity, loadWhisper: false);
      engine
        ..onState = _onEngineState
        ..onPartial = _onPartial
        ..onLevel = _onLevel
        ..onDone = _onDone
        ..beforeTranscribe = _beforeTranscribe
        ..transcriber = _transcribe;
      _engine = engine;
      _log(
        'models ready in ${sw.elapsedMilliseconds} ms '
        '(whisper downloaded: ${paths.whisperReady})',
        status: 'Ready',
      );
      _startWhisper();

      // Beeps are nice to have; never let them stop the service.
      try {
        await _player.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              audioFocus: AndroidAudioFocus.none,
              usageType: AndroidUsageType.assistanceSonification,
              contentType: AndroidContentType.sonification,
            ),
          ),
        );
      } catch (e) {
        _log('beep setup failed (ignored): $e');
      }

      if (_pendingStart) {
        _pendingStart = false;
        _log('starting the capture requested while loading');
        engine.start();
      }
      step = 'starting microphone';
      await _syncMic();
      _sendState();
    } catch (e, st) {
      _log(
        'FAILED while $step: $e\n$st',
        status: 'Voice engine failed',
        error: true,
      );
      FlutterForegroundTask.sendDataToMain({
        'type': Msg.error,
        'message': 'Voice service failed while $step: $e',
      });
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) => _reportMicHealth();

  Future<void> _reportMicHealth() async {
    final chunks = _healthChunks;
    final peak = _healthPeak / 32768;
    _healthChunks = 0;
    _healthPeak = 0;
    final engine = _engine;
    if (engine == null) return;
    final needMic = engine.wakeEnabled || engine.state != EngineState.idle;
    if (!needMic) return;
    if (_mic == null) {
      // A failed (re)start: keep trying.
      await _restartMic('microphone was off');
      return;
    }
    final open = await FlutterForegroundTask.isAppOnForeground;
    if (++_healthTicks % 3 == 0) {
      _log(
        'mic health (app ${open ? 'open' : 'in background'}, '
        '${engine.state.name}): $chunks chunks in 10 s, '
        'peak ${(peak * 100).toStringAsFixed(1)}%',
      );
    }
    if (chunks == 0) {
      await _restartMic('no audio for 10 s');
      return;
    }
    if (peak > 0 || engine.state != EngineState.idle) {
      _silentChecks = 0;
      return;
    }
    _silentChecks++;
    if (_silentChecks == 2 &&
        DateTime.now().difference(_lastRestart) > const Duration(minutes: 2)) {
      await _restartMic(
        'pure silence for 20 s (app ${open ? 'open' : 'in background'})',
      );
    } else if (_silentChecks >= 6 && !_warnedMuted) {
      _warnedMuted = true;
      _log(
        'the microphone is still delivering pure silence after a restart: '
        'the phone is blocking it',
        error: true,
      );
      FlutterForegroundTask.updateService(
        notificationTitle: 'Hey Notes can’t hear you',
        notificationText: 'Open the app to turn listening back on.',
      );
    }
  }

  /// Stops and reopens the microphone stream. Clears a recorder stuck or
  /// muted after a note (the "saved" beep, an audio route change...).
  Future<void> _restartMic(String why) async {
    if (_restartingMic) return;
    _restartingMic = true;
    _lastRestart = DateTime.now();
    try {
      final mic = _mic;
      _mic = null;
      if (mic != null) {
        await mic.cancel();
        await _recorder.stop();
      }
      await _syncMic();
      _log('microphone restarted ($why)');
    } catch (e) {
      _log('microphone restart failed ($why): $e', error: true);
    } finally {
      _restartingMic = false;
    }
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    try {
      _handle(data);
    } catch (e, st) {
      _log('command ${data['cmd']} failed: $e\n$st', error: true);
    }
  }

  void _handle(Map<dynamic, dynamic> data) {
    final engine = _engine;
    switch (data['cmd']) {
      case Msg.start:
        if (engine == null) {
          _pendingStart = true;
          _log('start requested while loading; will start when ready');
          return;
        }
        engine.start();
        _syncMic().catchError(_micFailed);
      case Msg.stop:
        engine?.finish();
      case Msg.cancel:
        _userCancelled = true;
        engine?.cancel();
      case Msg.reload:
        _reload();
      case Msg.ping:
        _sendState();
        _log(
          'ping: engine ${engine == null ? 'loading' : engine.state.name}, '
          'mic ${_mic == null ? 'off' : 'on'}, chunks $_pcmChunks',
          status: engine == null ? null : 'Ready',
        );
    }
  }

  void _micFailed(Object e) {
    _log('microphone failed: $e', status: 'Microphone failed', error: true);
    FlutterForegroundTask.sendDataToMain({
      'type': Msg.error,
      'message': 'Could not use the microphone: $e',
    });
    _engine?.cancel();
  }

  Future<void> _reload() async {
    _settings = await AppSettings.load();
    final engine = _engine;
    if (engine == null) return;
    engine
      ..wakeEnabled = _settings.wakeEnabled
      ..silenceSecs = _settings.silenceSecs
      ..sensitivity = _settings.sensitivity;
    _startWhisper();
    await _syncMic().catchError(_micFailed);
    await _stopIfUnneeded();
    _updateNotification();
  }

  /// Speech segments → text. Cloud (Intron Sahara via the Hey Notes API)
  /// when chosen, falling back to on-device Whisper when offline, slow or
  /// failing; Whisper when chosen. Throwing makes the engine use the
  /// streaming model's text, so a note is never lost.
  Future<String> _transcribe(List<Float32List> segments) async {
    final secs =
        (segments.fold(0, (n, s) => n + s.length) / VoiceEngine.sampleRate)
            .toStringAsFixed(1);
    if (_settings.engine == AppSettings.engineCloud) {
      final sw = Stopwatch()..start();
      try {
        final text = await _cloud
            .transcribe(segments, VoiceEngine.sampleRate)
            .timeout(const Duration(seconds: 20));
        _lastEngine = 'Sahara';
        _log(
          'Sahara (cloud): $secs s of speech in ${sw.elapsedMilliseconds} ms',
        );
        return text;
      } catch (e) {
        _log(
          'cloud failed after ${sw.elapsedMilliseconds} ms ($e); using on-device',
          error: true,
        );
      }
    }
    final worker = _whisper;
    if (worker == null) {
      _lastEngine = 'streaming';
      throw StateError('Whisper is not downloaded');
    }
    // Never let a stuck worker leave the engine "transcribing" (deaf to
    // the wake word) forever.
    final text = await worker
        .transcribe(segments, VoiceEngine.sampleRate)
        .timeout(const Duration(seconds: 30));
    _lastEngine = 'Whisper';
    _log(
      'Whisper: $secs s of speech in ${worker.lastDuration.inMilliseconds} ms '
      '(${whisperThreads()} threads)',
    );
    return text;
  }

  /// Loads Whisper on its worker isolate, once it has been downloaded.
  Future<void> _startWhisper() => _whisperStarting ??= () async {
    final engine = _engine;
    if (engine == null || _whisper != null) return;
    if (!engine.paths.whisperReady) return;
    final sw = Stopwatch()..start();
    try {
      _whisper = await WhisperWorker.spawn(engine.paths);
      _log('Whisper ready on its own thread in ${sw.elapsedMilliseconds} ms');
    } catch (e) {
      _log('Whisper failed to load: $e', error: true);
    } finally {
      _whisperStarting = null;
    }
  }();

  /// The mic is on while listening for the wake word or capturing a note.
  Future<void> _syncMic() async {
    final engine = _engine;
    final need =
        engine != null &&
        (engine.wakeEnabled || engine.state != EngineState.idle);
    if (need && _mic == null) {
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: VoiceEngine.sampleRate,
          numChannels: 1,
          audioInterruption: AudioInterruptionMode.none,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceRecognition,
            manageBluetooth: false,
          ),
        ),
      );
      _pcmChunks = 0;
      _mic = stream.listen(
        _onPcm,
        onError: (Object e) => _log('mic stream error: $e', error: true),
        onDone: () {
          // Ended without us stopping it: the watchdog reopens it.
          if (_mic != null && !_restartingMic) {
            _log('mic stream ended unexpectedly', error: true);
            _mic = null;
          }
        },
      );
      _log('microphone on');
    } else if (!need && _mic != null) {
      await _mic?.cancel();
      _mic = null;
      await _recorder.stop();
      _log('microphone off');
    }
  }

  /// With the wake word off, the service only lives for one capture.
  Future<void> _stopIfUnneeded() async {
    final engine = _engine;
    if (engine != null &&
        !engine.wakeEnabled &&
        engine.state == EngineState.idle) {
      await FlutterForegroundTask.stopService();
    }
  }

  void _onPcm(Uint8List bytes) {
    if (++_pcmChunks == 1) {
      _log('first audio chunk: ${bytes.length} bytes');
    }
    // 16-bit little-endian PCM; a chunk can end mid-sample.
    var data = bytes;
    if (_carry != null) {
      data = Uint8List(bytes.length + 1)
        ..[0] = _carry!
        ..setAll(1, bytes);
      _carry = null;
    }
    final n = data.length ~/ 2;
    if (data.length.isOdd) _carry = data.last;
    final view = ByteData.sublistView(data);
    final samples = Float32List(n);
    var peak = _healthPeak;
    for (var i = 0; i < n; i++) {
      final v = view.getInt16(i * 2, Endian.little);
      if (v.abs() > peak) peak = v.abs();
      samples[i] = v / 32768.0;
    }
    _healthPeak = peak;
    _healthChunks++;
    try {
      _engine?.accept(samples);
    } catch (e, st) {
      if (!_acceptFailed) _log('audio processing failed: $e\n$st', error: true);
      _acceptFailed = true;
    }
  }

  void _onEngineState(EngineState s, {bool byWake = false}) {
    if (s == EngineState.capturing) {
      _log('capture started (${byWake ? '“Hey Notes”' : 'mic button'})');
      _partial = '';
      if (_settings.beep) _play('sounds/wake.wav');
      _maybeShowOverlay();
    }
    _sendState(byWake: byWake);
    _updateNotification();
  }

  void _onPartial(String text) => _partial = text;

  /// Outside the app, "Hey Notes" lights up the screen edges and shows a
  /// bubble (needs "Display over other apps"). Inside, the app's own
  /// Listening screen does that job.
  Future<void> _maybeShowOverlay() async {
    _overlayHide?.cancel();
    _overlayOn = false;
    try {
      if (!_settings.overlayEnabled) return;
      if (await FlutterForegroundTask.isAppOnForeground) return;
      if (!await ho.HeyOverlay.canDraw()) {
        _log('overlay skipped: “Display over other apps” is not allowed');
        return;
      }
      if (_engine?.state != EngineState.capturing) return;
      _overlayOn = true;
      await ho.HeyOverlay.show(ho.OverlayState.listening);
    } catch (e) {
      _log('overlay failed: $e', error: true);
    }
  }

  String get _liveText =>
      cleanTranscript(_partial).replaceAll(RegExp(r'\.$'), '…');

  /// Shows a final overlay state, then removes the overlay shortly after.
  void _finishOverlay(ho.OverlayState? state, {String text = ''}) {
    if (!_overlayOn) return;
    _overlayOn = false;
    _overlayHide?.cancel();
    if (state == null) {
      ho.HeyOverlay.hide().catchError((_) {});
      return;
    }
    ho.HeyOverlay.show(state, text: text).catchError((_) {});
    _overlayHide = Timer(
      const Duration(milliseconds: 1800),
      () => ho.HeyOverlay.hide().catchError((_) {}),
    );
  }

  /// Runs between "stopped listening" and the Whisper pass, which blocks
  /// this isolate for a few seconds: get "turning your voice into text" onto
  /// the notification and overlay first, so nothing looks stuck on
  /// "listening" while we convert.
  Future<void> _beforeTranscribe() async {
    _log('converting speech to text');
    try {
      await Future.wait([
        _updateNotification(),
        if (_overlayOn)
          ho.HeyOverlay.show(ho.OverlayState.transcribing, text: _liveText),
      ]).timeout(const Duration(seconds: 1));
    } catch (_) {
      // A slow notification or overlay must never block saving the note.
    }
    // Let the app and the overlay draw a frame before we block.
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  void _onLevel(double level) {
    _level = level;
    final now = DateTime.now();
    if (now.difference(_lastPartialSent).inMilliseconds < 90) return;
    _lastPartialSent = now;
    if (_overlayOn) {
      ho.HeyOverlay.show(
        ho.OverlayState.listening,
        text: _partial.isEmpty ? '' : _liveText,
        level: level,
      ).catchError((_) {});
    }
    FlutterForegroundTask.sendDataToMain({
      'type': Msg.partial,
      'text': _partial,
      'level': _level,
    });
  }

  Future<void> _onDone(CaptureResult? result) async {
    if (result == null) {
      _log(
        _userCancelled ? 'capture cancelled' : 'capture ended: nothing heard',
      );
      if (!_userCancelled) {
        FlutterForegroundTask.sendDataToMain({'type': Msg.nothing});
      }
      _finishOverlay(_userCancelled ? null : ho.OverlayState.nothing);
      _userCancelled = false;
      _updateNotification();
      await _restartMic('after capture');
      await _stopIfUnneeded();
      return;
    }
    try {
      String? audioPath;
      if (_settings.keepAudio) {
        final dir = Directory(
          '${(await getApplicationSupportDirectory()).path}/audio',
        );
        await dir.create(recursive: true);
        audioPath = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.wav';
        if (!so.writeWave(
          filename: audioPath,
          samples: result.samples,
          sampleRate: VoiceEngine.sampleRate,
        )) {
          audioPath = null;
        }
      }
      final note = Note(
        title: makeTitle(result.text),
        body: result.text,
        createdAt: DateTime.now(),
        durationMs: result.durationMs,
        audioPath: audioPath,
      );
      final id = await _db.insert(note);
      _log(
        'note saved: ${result.durationMs ~/ 1000} s, '
        '${result.text.split(' ').length} words, '
        '${result.usedWhisper ? _lastEngine : 'streaming model'}',
      );
      if (_settings.beep) _play('sounds/saved.wav');
      FlutterForegroundTask.sendDataToMain({
        'type': Msg.saved,
        'id': id,
        'byWake': result.byWake,
        'whisper': result.usedWhisper,
        'engine': result.usedWhisper ? _lastEngine : 'streaming',
      });
      _updateNotification(savedTitle: note.title);
      _finishOverlay(ho.OverlayState.saved, text: note.title);
    } catch (e) {
      _finishOverlay(null);
      FlutterForegroundTask.sendDataToMain({
        'type': Msg.error,
        'message': 'Could not save note: $e',
      });
    }
    await _restartMic('after note');
    await _stopIfUnneeded();
  }

  void _play(String asset) {
    _player.play(AssetSource(asset)).catchError((_) {});
  }

  void _sendState({bool byWake = false}) {
    final engine = _engine;
    FlutterForegroundTask.sendDataToMain({
      'type': Msg.state,
      'state': (engine?.state ?? EngineState.idle).name,
      'byWake': byWake,
      'wakeEnabled': engine?.wakeEnabled ?? false,
      'whisper': engine?.whisperLoaded ?? false,
    });
  }

  Future<void> _updateNotification({String? savedTitle}) async {
    final engine = _engine;
    final text = switch (engine?.state) {
      EngineState.capturing => 'Listening… speak your note',
      EngineState.transcribing => 'Transcribing…',
      _ when savedTitle != null => 'Saved: $savedTitle',
      _ when engine?.wakeEnabled ?? false => 'Listening for “Hey Notes”',
      _ => 'Ready',
    };
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Hey Notes',
      notificationText: text,
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _overlayHide?.cancel();
    if (_overlayOn) await ho.HeyOverlay.hide().catchError((_) {});
    await _mic?.cancel();
    _mic = null;
    await _recorder.dispose();
    await _player.dispose();
    _whisper?.dispose();
    _whisper = null;
    _cloud.close();
    _engine?.dispose();
    _engine = null;
  }
}
