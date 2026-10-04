import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
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

  /// Saved with FlutterForegroundTask.saveData so a capture requested before
  /// the service finished starting isn't lost.
  static const pendingStartKey = 'pendingStart';
}

/// Entry point of the foreground service's isolate.
@pragma('vm:entry-point')
void startVoiceTask() {
  FlutterForegroundTask.setTaskHandler(VoiceTaskHandler());
}

/// Runs inside the Android foreground service: owns the microphone, runs the
/// [VoiceEngine] and saves notes to the local database.
class VoiceTaskHandler extends TaskHandler {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  StreamSubscription<Uint8List>? _mic;
  VoiceEngine? _engine;
  late NotesDb _db;
  late AppSettings _settings;
  int? _carry;
  DateTime _lastPartialSent = DateTime(0);
  String _partial = '';
  double _level = 0;
  bool _userCancelled = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      so.initBindings();
      _settings = await AppSettings.load();
      _db = await NotesDb.open();
      final paths = await ModelFiles.ensureBundled();
      await _player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            audioFocus: AndroidAudioFocus.none,
            usageType: AndroidUsageType.assistanceSonification,
            contentType: AndroidContentType.sonification,
          ),
        ),
      );

      final engine = _engine = VoiceEngine(paths)
        ..wakeEnabled = _settings.wakeEnabled
        ..silenceSecs = _settings.silenceSecs;
      engine.init(sensitivity: _settings.sensitivity);
      engine
        ..onState = _onEngineState
        ..onPartial = _onPartial
        ..onLevel = _onLevel
        ..onDone = _onDone;

      if (await FlutterForegroundTask.getData<bool>(key: Msg.pendingStartKey) ??
          false) {
        await FlutterForegroundTask.removeData(key: Msg.pendingStartKey);
        engine.start();
      }
      await _syncMic();
      _sendState();
    } catch (e) {
      FlutterForegroundTask.sendDataToMain({
        'type': Msg.error,
        'message': 'Voice service failed to start: $e',
      });
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final engine = _engine;
    switch (data['cmd']) {
      case Msg.start:
        if (engine == null) return;
        engine.start();
        _syncMic();
      case Msg.stop:
        engine?.finish();
      case Msg.cancel:
        _userCancelled = true;
        engine?.cancel();
      case Msg.reload:
        _reload();
      case Msg.ping:
        _sendState();
    }
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
    await _syncMic();
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
      _mic = stream.listen(_onPcm);
    } else if (!need && _mic != null) {
      await _mic?.cancel();
      _mic = null;
      await _recorder.stop();
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
    for (var i = 0; i < n; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    _engine?.accept(samples);
  }

  void _onEngineState(EngineState s, {bool byWake = false}) {
    if (s == EngineState.capturing) {
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
      if (!_userCancelled) {
        FlutterForegroundTask.sendDataToMain({'type': Msg.nothing});
      }
      _userCancelled = false;
      _updateNotification();
      await _syncMic();
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
    await _syncMic();
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
