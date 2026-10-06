import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:hey_overlay/hey_overlay.dart' as ho;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../data/note.dart';
import '../data/notes_db.dart';
import '../data/reminders.dart';
import '../data/settings.dart';
import '../util/commands.dart';
import '../util/log_file.dart';
import '../util/memory.dart';
import '../util/reminder_time.dart';
import '../util/text.dart';
import 'cloud.dart';
import 'model_files.dart';
import 'voice_engine.dart';
import 'offline_asr.dart';

/// Messages between the UI and the background voice service.
abstract final class Msg {
  // UI -> service
  static const start = 'start';
  static const stop = 'stop';
  static const cancel = 'cancel';
  static const reload = 'reload';
  static const ping = 'ping';
  static const retry = 'retry';
  static const retryTidy = 'retryTidy';

  // service -> UI
  static const state = 'state';
  static const partial = 'partial';
  static const saved = 'saved';
  static const nothing = 'nothing';
  static const error = 'error';
  static const retried = 'retried';

  /// One diagnostics line: {'type': log, 'line': ..., 'status': ...?}.
  static const log = 'log';

  /// Saved with FlutterForegroundTask.saveData so a capture requested before
  /// the service finished starting isn't lost.
  static const pendingStartKey = 'pendingStart';

  /// A note id to retry once the service has started.
  static const pendingRetryKey = 'pendingRetry';
  static const pendingRetryTidyKey = 'pendingRetryTidy';
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

  final _cloud = CloudTranscriber();

  /// Which engine produced the last transcript, for the log and the UI.
  String _lastEngine = 'streaming';
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
    LogFile.append('[service] ${error ? 'ERROR ' : ''}$line');
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
        'loading models (downloaded: '
        '${OfflineModel.values.where(paths.isReady).map((m) => m.label).join(', ')})',
        status: 'Loading speech models…',
      );
      final engine = VoiceEngine(paths)
        ..wakeEnabled = _settings.wakeEnabled
        ..silenceSecs = _settings.silenceSecs;
      // On-device models run on their own isolates (_syncWorkers).
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
        '(engine: ${_settings.engine})',
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
      final pendingRetry = await FlutterForegroundTask.getData<int>(
        key: Msg.pendingRetryKey,
      );
      if (pendingRetry != null) {
        await FlutterForegroundTask.removeData(key: Msg.pendingRetryKey);
        _retry(pendingRetry);
      }
      final pendingTidy = await FlutterForegroundTask.getData<int>(
        key: Msg.pendingRetryTidyKey,
      );
      if (pendingTidy != null) {
        await FlutterForegroundTask.removeData(key: Msg.pendingRetryTidyKey);
        _retryTidy(pendingTidy);
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
  void onRepeatEvent(DateTime timestamp) {
    _reportMicHealth();
    if (++_autoTicks % 3 == 0) _autoRetry();
  }

  // "Retry when back online": every 30 s, notes that failed for lack of a
  // connection are retried once the API's host resolves again. At most
  // [_maxAutoRetries] tries per note, a minute or more apart; Retry on the
  // note still works after that.
  static const _maxAutoRetries = 3;
  int _autoTicks = 0;
  bool _autoBusy = false;
  final _lastAutoTry = <int, DateTime>{};

  /// Failures a connection can fix (not an on-device model's, and not a
  /// reminder time the API couldn't work out).
  static const _cloudFailures = {
    _noInternet,
    'The cloud took too long',
    'Too many notes right now, try again in a minute',
    'The cloud couldn’t transcribe it',
  };
  static const _tidyFailures = {
    _noInternet,
    'Tidying took too long',
    'Tidying failed',
  };
  static const _noInternet = 'No internet connection';

  Future<void> _autoRetry() async {
    final engine = _engine;
    if (!_settings.retryOnline || _autoBusy || engine == null) return;
    if (engine.state != EngineState.idle) return;
    _autoBusy = true;
    try {
      final now = DateTime.now();
      final cloud = _settings.engine == AppSettings.engineCloud;
      final due = [
        for (final n in await _db.failedForAutoRetry(_maxAutoRetries))
          if ((n.failed
                  ? cloud && _cloudFailures.contains(n.error)
                  : _tidyFailures.contains(n.tidyError)) &&
              now.difference(_lastAutoTry[n.id] ?? DateTime(0)) >
                  const Duration(minutes: 1))
            n,
      ];
      if (due.isEmpty || !await _online()) return;
      for (final n in due) {
        if (engine.state != EngineState.idle) break;
        final id = n.id!;
        _lastAutoTry[id] = DateTime.now();
        await _db.update(n.copyWith(autoRetries: n.autoRetries + 1));
        _log('back online: retrying note $id (try ${n.autoRetries + 1})');
        n.failed
            ? await _retry(id, auto: true)
            : await _retryTidy(id, auto: true);
      }
    } catch (e) {
      _log('retry when back online failed: $e', error: true);
    } finally {
      _autoBusy = false;
    }
  }

  /// Whether the API's host resolves (a cheap "are we online?").
  Future<bool> _online() async {
    try {
      final r = await InternetAddress.lookup(Uri.parse(apiBaseUrl).host)
          .timeout(const Duration(seconds: 5));
      return r.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

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
      case Msg.retry:
        final id = data['id'];
        if (id is int) _retry(id);
      case Msg.retryTidy:
        final id = data['id'];
        if (id is int) _retryTidy(id);
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
    await _syncMic().catchError(_micFailed);
    await _stopIfUnneeded();
    _updateNotification();
  }

  /// Speech segments → text with the engine the user chose, and only that
  /// one. Failures throw a [TranscriptionError] with a reason fit to show;
  /// the note is then kept as "not transcribed" (no quiet fallback).
  Future<String> _transcribe(List<Float32List> segments) async {
    final secs =
        (segments.fold(0, (n, s) => n + s.length) / VoiceEngine.sampleRate)
            .toStringAsFixed(1);
    final sw = Stopwatch()..start();
    final model = AppSettings.modelFor(_settings.engine);
    if (model == null) {
      try {
        final text = await _cloud
            .transcribe(segments, VoiceEngine.sampleRate)
            .timeout(const Duration(seconds: 20));
        _lastEngine = 'Cloud';
        _log('Cloud: $secs s of speech in ${sw.elapsedMilliseconds} ms');
        return text;
      } catch (e) {
        _log(
          'cloud failed after ${sw.elapsedMilliseconds} ms: $e',
          error: true,
        );
        throw TranscriptionError(_cloudReason(e));
      }
    }
    return _transcribeOnDevice(model, segments, secs, sw);
  }

  /// Loads [model] just for this note, transcribes, and unloads it, so
  /// nothing heavy sits in memory while listening for "Hey Notes".
  Future<String> _transcribeOnDevice(
    OfflineModel model,
    List<Float32List> segments,
    String secs,
    Stopwatch sw,
  ) async {
    final paths = _engine!.paths;
    if (!paths.isReady(model)) {
      throw TranscriptionError('${model.label} isn’t downloaded');
    }
    final mem = await DeviceMemory.read();
    if (mem != null && !model.supportsDevice(mem.total)) {
      throw TranscriptionError('This phone can’t run ${model.label}');
    }
    if (mem != null && mem.available < model.runtimeBytes * 1.1) {
      _log(
        '${model.label}: needs ${model.runtimeBytes ~/ mb} MB, '
        '${mem.available ~/ mb} MB free',
        error: true,
      );
      throw TranscriptionError('Not enough free memory for ${model.label}');
    }
    OfflineWorker? worker;
    try {
      worker = await OfflineWorker.spawn(
        model,
        paths,
      ).timeout(const Duration(seconds: 60));
      final loadMs = sw.elapsedMilliseconds;
      final text = await worker
          .transcribe(segments, VoiceEngine.sampleRate)
          .timeout(const Duration(seconds: 90));
      _lastEngine = model.label;
      _log(
        '${model.label}: $secs s of speech in '
        '${worker.lastDuration.inMilliseconds} ms '
        '(+$loadMs ms to load, ${offlineThreads()} threads)',
      );
      return text;
    } on TimeoutException {
      _log(
        '${model.label} timed out after ${sw.elapsedMilliseconds} ms',
        error: true,
      );
      throw TranscriptionError('${model.label} took too long');
    } catch (e) {
      _log('${model.label} failed: $e', error: true);
      throw TranscriptionError('${model.label} couldn’t run');
    } finally {
      worker?.dispose();
    }
  }

  /// Tidies a transcript when the setting is on (or [force]), and works
  /// out the time of a "remind me …" note ([remind]) even when it's off.
  /// Returns null when there's nothing to do; on failure, [error] is set
  /// and the raw text is kept (never silently).
  Future<_Tidied?> _tidyText(
    String raw, {
    bool remind = false,
    bool force = false,
  }) async {
    final tidy = force || _settings.tidyEnabled;
    if (!tidy && !remind) return null;
    final sw = Stopwatch()..start();
    try {
      final now = DateTime.now();
      final t = await _cloud
          .tidy(raw, now: remind ? localNow(now) : null)
          .timeout(const Duration(seconds: 30));
      _log('tidied in ${sw.elapsedMilliseconds} ms');
      final at = remind && t.reminder != null
          ? checkReminderAt(t.reminder!.at, now)
          : null;
      if (remind) _log('reminder: ${t.reminder?.at} -> $at');
      return (
        title: tidy ? t.title : null,
        text: tidy ? t.text : null,
        error: remind && at == null ? reminderUnclear : null,
        remindAt: at,
        what: at == null ? null : t.reminder!.what,
      );
    } catch (e) {
      _log('tidy failed after ${sw.elapsedMilliseconds} ms: $e', error: true);
      return (
        title: null,
        text: null,
        error: _tidyReason(e),
        remindAt: null,
        what: null,
      );
    }
  }

  /// Schedules [note]'s reminder (if it has one) under its id.
  Future<void> _scheduleReminder(int id, _Tidied? t) async {
    final at = t?.remindAt;
    if (at == null) return;
    try {
      final exact = await Reminders.schedule(id, at, t!.what ?? 'Reminder');
      _log('reminder for note $id at $at${exact ? '' : ' (inexact)'}');
    } catch (e) {
      _log('could not schedule reminder for note $id: $e', error: true);
    }
  }

  static String _tidyReason(Object e) {
    if (e is TimeoutException) return 'Tidying took too long';
    if (e is SocketException || e is http.ClientException) {
      return _noInternet;
    }
    return 'Tidying failed';
  }

  /// Re-tidies a note from its original transcript.
  Future<void> _retryTidy(int id, {bool auto = false}) async {
    final note = await _db.get(id);
    String? error;
    if (note == null) {
      error = 'The note is gone';
    } else {
      final raw = note.transcript ?? note.body;
      final remind = parseCommands(raw).remind;
      final t = (await _tidyText(raw, remind: remind, force: !remind))!;
      error = t.error;
      final text = t.text;
      await _db.update(
        note.copyWith(
          title: t.title,
          body: text == null
              ? null
              : note.body.contains('- [ ] ') || note.body.contains('- [x] ')
              ? toChecklist(text)
              : text,
          transcript: text == null ? null : () => text != raw ? raw : null,
          tidyError: () => error,
          remindAt: t.remindAt == null ? null : () => t.remindAt,
          retriedOnline: auto && error == null ? true : null,
        ),
      );
      await _scheduleReminder(id, t);
      _log(
        error == null
            ? 'retry tidy succeeded for note $id'
            : 'retry tidy failed for note $id: $error',
        error: error != null,
      );
    }
    FlutterForegroundTask.sendDataToMain({
      'type': Msg.retried,
      'id': id,
      'error': ?error,
      'auto': auto,
    });
    await _stopIfUnneeded();
  }

  static String _cloudReason(Object e) {
    if (e is TimeoutException) return 'The cloud took too long';
    if (e is SocketException || e is http.ClientException) {
      return _noInternet;
    }
    if (e is CloudError && e.message.startsWith('HTTP 429')) {
      return 'Too many notes right now, try again in a minute';
    }
    return 'The cloud couldn’t transcribe it';
  }

  /// Re-transcribes a note that failed, with the engine chosen now.
  Future<void> _retry(int id, {bool auto = false}) async {
    final note = await _db.get(id);
    final audio = note?.audioPath;
    if (note == null || audio == null || !File(audio).existsSync()) {
      FlutterForegroundTask.sendDataToMain({
        'type': Msg.retried,
        'id': id,
        'error': 'The recording for this note is gone',
        'auto': auto,
      });
      return;
    }
    _log('retrying note $id');
    final samples = so.readWave(audio).samples;
    // Whisper takes at most 30 s at a time.
    const step = 25 * VoiceEngine.sampleRate;
    final segments = [
      for (var i = 0; i < samples.length; i += step)
        Float32List.sublistView(
          samples,
          i,
          (i + step).clamp(0, samples.length),
        ),
    ];
    String? error;
    try {
      final text = cleanTranscript(await _transcribe(segments));
      if (text.isEmpty) {
        error = 'Nothing to transcribe in this recording';
      } else {
        final cmds = parseCommands(text);
        final spoken = cmds.text.isNotEmpty ? cmds.text : text;
        final tidied = await _tidyText(spoken, remind: cmds.remind);
        var body = tidied?.text ?? spoken;
        if (cmds.checklist) body = toChecklist(body);
        var updated = note.copyWith(
          title: tidied?.title ?? makeTitle(spoken),
          body: body,
          error: () => null,
          transcript: () =>
              tidied?.text != null && tidied!.text != spoken ? text : null,
          tidyError: () => tidied?.error,
          tags: {...note.tags, ...cmds.tags}.toList(),
          remindAt: () => tidied?.remindAt,
          retriedOnline: auto ? true : null,
        );
        // The recording was only kept so the note could be retried.
        if (!_settings.keepAudio) {
          updated = updated.withoutAudio();
          await File(audio).delete().catchError((_) => File(audio));
        }
        await _db.update(updated);
        await _scheduleReminder(id, tidied);
        _log('retry succeeded for note $id');
      }
    } on TranscriptionError catch (e) {
      error = e.message;
    }
    if (error != null) await _db.update(note.copyWith(error: () => error));
    FlutterForegroundTask.sendDataToMain({
      'type': Msg.retried,
      'id': id,
      'error': ?error,
      'auto': auto,
    });
    await _stopIfUnneeded();
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
      // A failed note always keeps its recording, so it can be retried.
      if (_settings.keepAudio || result.failed) {
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
      final failed = result.error;
      // Spoken commands ("tag it work", "make it a checklist", "add this
      // to my last note") are matched in code and removed from the text.
      final cmds = failed == null ? parseCommands(result.text) : null;
      final spoken = cmds != null && cmds.text.isNotEmpty
          ? cmds.text
          : result.text;
      if (cmds != null && cmds.any) {
        _log(
          'commands: ${[if (cmds.append) 'append', if (cmds.checklist) 'checklist', if (cmds.remind) 'remind', ...cmds.tags.map((t) => 'tag:$t')].join(', ')}',
        );
      }
      final tidied = failed == null
          ? await _tidyText(spoken, remind: cmds!.remind)
          : null;
      var body = tidied?.text ?? spoken;
      if (cmds?.checklist ?? false) body = toChecklist(body);
      final last = (cmds?.append ?? false) ? await _db.latest() : null;
      final Note note;
      final int id;
      if (last != null && !last.failed) {
        // "Add this to my last note": extend it instead of a new note.
        note = last.copyWith(
          body: '${last.body}\n\n$body',
          transcript: () => last.transcript == null && tidied?.text == null
              ? null
              : '${last.transcript ?? last.body}\n\n$spoken',
          tags: {...last.tags, ...cmds!.tags}.toList(),
          tidyError: tidied?.error == null ? null : () => tidied!.error,
          remindAt: tidied?.remindAt == null ? null : () => tidied!.remindAt,
        );
        await _db.update(note);
        id = last.id!;
        _log('added to note $id');
        // The appended part's recording isn't attached to any note.
        if (audioPath != null) {
          await File(audioPath).delete().catchError((_) => File(audioPath!));
        }
      } else {
        note = Note(
          title: failed != null
              ? 'Not transcribed'
              : tidied?.title ?? makeTitle(spoken),
          body: body,
          createdAt: DateTime.now(),
          durationMs: result.durationMs,
          audioPath: audioPath,
          error: failed,
          transcript: tidied?.text != null && tidied!.text != spoken
              ? result.text
              : null,
          tidyError: tidied?.error,
          tags: cmds?.tags ?? const [],
          remindAt: tidied?.remindAt,
        );
        id = await _db.insert(note);
      }
      await _scheduleReminder(id, tidied);
      if (failed != null) {
        _log(
          'note $id saved NOT transcribed (${result.durationMs ~/ 1000} s): '
          '$failed',
          error: true,
        );
      } else {
        _log(
          'note saved: ${result.durationMs ~/ 1000} s, '
          '${result.text.split(' ').length} words, '
          '${result.usedWhisper ? _lastEngine : 'streaming model'}',
        );
        if (_settings.beep) _play('sounds/saved.wav');
      }
      FlutterForegroundTask.sendDataToMain({
        'type': Msg.saved,
        'id': id,
        'byWake': result.byWake,
        'whisper': result.usedWhisper,
        'engine': result.usedWhisper ? _lastEngine : 'streaming',
        'error': ?failed,
      });
      if (failed != null) {
        _updateNotification(failedReason: failed);
        _finishOverlay(ho.OverlayState.failed, text: failed);
      } else {
        _updateNotification(savedTitle: note.title);
        _finishOverlay(ho.OverlayState.saved, text: note.title);
      }
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

  Future<void> _updateNotification({
    String? savedTitle,
    String? failedReason,
  }) async {
    final engine = _engine;
    final text = switch (engine?.state) {
      EngineState.capturing => 'Listening… speak your note',
      EngineState.transcribing => 'Transcribing…',
      _ when failedReason != null => 'Couldn’t transcribe: $failedReason',
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
    _cloud.close();
    _engine?.dispose();
    _engine = null;
  }
}

typedef _Tidied = ({
  String? title,
  String? text,
  String? error,
  DateTime? remindAt,
  String? what,
});
