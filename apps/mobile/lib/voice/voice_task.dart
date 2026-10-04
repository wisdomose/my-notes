import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../data/note.dart';
import '../data/notes_db.dart';
import '../data/settings.dart';
import '../util/text.dart';
import 'model_files.dart';
import 'voice_engine.dart';

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
  late NotesDb _db;
  late AppSettings _settings;
  int? _carry;
  DateTime _lastPartialSent = DateTime(0);
  String _partial = '';
  double _level = 0;
  bool _userCancelled = false;

  /// A start request that arrived while the models were still loading.
  bool _pendingStart = false;
  int _pcmChunks = 0;
  bool _acceptFailed = false;

  // Mic health, reported every 30 s (onRepeatEvent). Pure digital silence
  // (peak exactly 0) means Android muted the mic for a background app; a
  // real quiet room still has noise.
  int _healthChunks = 0;
  int _healthPeak = 0;
  int _silentReports = 0;
  bool _warnedMuted = false;

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
      engine.init(sensitivity: _settings.sensitivity);
      engine
        ..onState = _onEngineState
        ..onPartial = _onPartial
        ..onLevel = _onLevel
        ..onDone = _onDone;
      _engine = engine;
      _log(
        'models ready in ${sw.elapsedMilliseconds} ms '
        '(whisper loaded: ${engine.whisperLoaded})',
        status: 'Ready',
      );

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
    if (_mic == null) return;
    final open = await FlutterForegroundTask.isAppOnForeground;
    _log(
      'mic health (app ${open ? 'open' : 'in background'}): '
      '$chunks chunks in 30 s, peak ${(peak * 100).toStringAsFixed(1)}%',
    );
    if (chunks == 0) {
      _log('no audio for 30 s: the microphone stream stopped', error: true);
      return;
    }
    if (peak > 0) {
      _silentReports = 0;
      return;
    }
    if (++_silentReports >= 2 && !_warnedMuted) {
      _warnedMuted = true;
      _log(
        'the microphone is delivering pure silence (app '
        '${open ? 'open' : 'in background'}): the phone is blocking it',
        error: true,
      );
      FlutterForegroundTask.updateService(
        notificationTitle: 'Hey Notes can’t hear you',
        notificationText:
            'The phone muted the microphone. Open the app to fix.',
      );
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
      ..sensitivity = _settings.sensitivity
      ..loadWhisperIfReady();
    await _syncMic().catchError(_micFailed);
    await _stopIfUnneeded();
    _updateNotification();
  }

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
        onDone: () => _log('mic stream ended'),
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
    }
    _sendState(byWake: byWake);
    _updateNotification();
  }

  void _onPartial(String text) => _partial = text;

  void _onLevel(double level) {
    _level = level;
    final now = DateTime.now();
    if (now.difference(_lastPartialSent).inMilliseconds < 90) return;
    _lastPartialSent = now;
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
      _userCancelled = false;
      _updateNotification();
      await _syncMic().catchError(_micFailed);
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
        '${result.usedWhisper ? 'Whisper' : 'streaming model'}',
      );
      if (_settings.beep) _play('sounds/saved.wav');
      FlutterForegroundTask.sendDataToMain({
        'type': Msg.saved,
        'id': id,
        'byWake': result.byWake,
        'whisper': result.usedWhisper,
      });
      _updateNotification(savedTitle: note.title);
    } catch (e) {
      FlutterForegroundTask.sendDataToMain({
        'type': Msg.error,
        'message': 'Could not save note: $e',
      });
    }
    await _syncMic().catchError(_micFailed);
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

  void _updateNotification({String? savedTitle}) {
    final engine = _engine;
    final text = switch (engine?.state) {
      EngineState.capturing => 'Listening… speak your note',
      EngineState.transcribing => 'Saving your note…',
      _ when savedTitle != null => 'Saved: $savedTitle',
      _ when engine?.wakeEnabled ?? false => 'Listening for “Hey Notes”',
      _ => 'Ready',
    };
    FlutterForegroundTask.updateService(
      notificationTitle: 'Hey Notes',
      notificationText: text,
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _mic?.cancel();
    _mic = null;
    await _recorder.dispose();
    await _player.dispose();
    _engine?.dispose();
    _engine = null;
  }
}
