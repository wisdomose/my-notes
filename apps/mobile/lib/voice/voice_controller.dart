import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/settings.dart';
import 'model_files.dart';
import 'voice_engine.dart';
import 'voice_task.dart';

class SavedEvent {
  const SavedEvent(this.noteId, {required this.byWake, required this.whisper});
  final int noteId;
  final bool byWake;
  final bool whisper;
}

/// UI-side handle on the background voice service.
class VoiceController extends ChangeNotifier {
  VoiceController(this.settings);

  final AppSettings settings;

  EngineState state = EngineState.idle;
  bool byWake = false;
  bool serviceRunning = false;
  String partial = '';
  final List<double> levels = List.filled(28, 0, growable: true);
  DateTime? captureStartedAt;
  String? error;

  final _saved = StreamController<SavedEvent>.broadcast();
  final _nothing = StreamController<void>.broadcast();
  Stream<SavedEvent> get saved => _saved.stream;
  Stream<void> get nothingHeard => _nothing.stream;

  void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'hey_notes_listening',
        channelName: 'Listening',
        channelDescription: 'Shown while Hey Notes listens for the wake word',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowAutoRestart: true,
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_onData);
    refresh();
  }

  Future<void> refresh() async {
    serviceRunning = await FlutterForegroundTask.isRunningService;
    if (serviceRunning) FlutterForegroundTask.sendDataToTask({'cmd': Msg.ping});
    notifyListeners();
  }

  void _onData(Object data) {
    if (data is! Map) return;
    switch (data['type']) {
      case Msg.state:
        final s = EngineState.values.byName(data['state'] as String);
        if (s == EngineState.capturing && state != EngineState.capturing) {
          captureStartedAt = DateTime.now();
          partial = '';
          levels.fillRange(0, levels.length, 0);
          byWake = data['byWake'] == true;
        }
        state = s;
        serviceRunning = true;
      case Msg.partial:
        partial = data['text'] as String? ?? '';
        levels
          ..removeAt(0)
          ..add((data['level'] as num?)?.toDouble() ?? 0);
      case Msg.saved:
        _saved.add(
          SavedEvent(
            data['id'] as int,
            byWake: data['byWake'] == true,
            whisper: data['whisper'] == true,
          ),
        );
      case Msg.nothing:
        _nothing.add(null);
      case Msg.error:
        error = data['message'] as String?;
    }
    notifyListeners();
  }

  /// Asks for the microphone (and notifications, for the service).
  Future<bool> ensurePermissions() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return false;
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    return true;
  }

  Future<bool> _startService() async {
    if (await FlutterForegroundTask.isRunningService) {
      serviceRunning = true;
      return true;
    }
    await ModelFiles.ensureBundled();
    final res = await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: 'Hey Notes',
      notificationText: settings.wakeEnabled
          ? 'Listening for “Hey Notes”'
          : 'Listening… speak your note',
      callback: startVoiceTask,
    );
    serviceRunning = res is ServiceRequestSuccess;
    if (res is ServiceRequestFailure) error = '${res.error}';
    notifyListeners();
    return serviceRunning;
  }

  /// Starts wake-word listening if enabled. Call when the app is visible:
  /// Android only lets a microphone service start from the foreground.
  Future<void> startListeningIfEnabled() async {
    if (!settings.wakeEnabled) return;
    if (!await ensurePermissions()) return;
    await _startService();
  }

  Future<void> setWakeEnabled(bool enabled) async {
    settings.wakeEnabled = enabled;
    await settings.save();
    if (enabled) {
      if (!await ensurePermissions()) {
        settings.wakeEnabled = false;
        await settings.save();
        error = 'Microphone permission is needed to listen for “Hey Notes”.';
        notifyListeners();
        return;
      }
      if (await FlutterForegroundTask.isRunningService) {
        settingsChanged();
      } else {
        await _startService();
      }
    } else {
      settingsChanged();
    }
    notifyListeners();
  }

  /// Tells the service to re-read settings and check for Whisper.
  void settingsChanged() {
    FlutterForegroundTask.sendDataToTask({'cmd': Msg.reload});
  }

  /// Manual capture from the mic button.
  Future<bool> startCapture() async {
    if (state != EngineState.idle) return true;
    if (!await ensurePermissions()) {
      error = 'Microphone permission is needed to record notes.';
      notifyListeners();
      return false;
    }
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask({'cmd': Msg.start});
      return true;
    }
    await FlutterForegroundTask.saveData(key: Msg.pendingStartKey, value: true);
    return _startService();
  }

  void stopCapture() => FlutterForegroundTask.sendDataToTask({'cmd': Msg.stop});

  void cancelCapture() =>
      FlutterForegroundTask.sendDataToTask({'cmd': Msg.cancel});

  void clearError() {
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    _saved.close();
    _nothing.close();
    super.dispose();
  }
}
