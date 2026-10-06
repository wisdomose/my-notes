import '../voice/model_files.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// User settings. Uses the uncached async API so the UI and the background
/// voice service always read the same values.
class AppSettings {
  AppSettings({
    this.wakeEnabled = true,
    this.sensitivity = 55,
    this.silenceSecs = 2.0,
    this.beep = true,
    this.keepAudio = false,
    this.overlayEnabled = true,
    this.engine = engineCloud,
    this.tidyEnabled = true,
  });

  bool wakeEnabled;

  /// 0 (fewest false wakes) .. 100 (hears you from further).
  double sensitivity;

  /// Seconds of silence that end a note.
  double silenceSecs;
  bool beep;
  bool keepAudio;

  /// Show the glowing-edge bubble over other apps after "Hey Notes".
  bool overlayEnabled;

  /// Who turns speech into text: [engineCloud] (Intron Sahara through the
  /// Hey Notes API; falls back to on-device), [engineDevice] (Whisper) or
  /// [engineParakeet].
  String engine;

  /// Tidy notes up (title, cleanup, lists) with AI through the API.
  bool tidyEnabled;
  static const engineCloud = 'cloud';
  static const engineDevice = 'device';
  static const engineParakeet = 'parakeet';

  /// The engine value for an on-device model (Whisper keeps its original
  /// value so existing settings still work).
  static String engineFor(OfflineModel m) =>
      m == OfflineModel.whisper ? engineDevice : m.name;

  /// The on-device model for [engine], or null for cloud.
  static OfflineModel? modelFor(String engine) => engine == engineCloud
      ? null
      : OfflineModel.values.firstWhere(
          (m) => engineFor(m) == engine,
          orElse: () => OfflineModel.whisper,
        );

  static const silenceOptions = [1.5, 2.0, 3.0];

  static Future<AppSettings> load() async {
    final p = SharedPreferencesAsync();
    return AppSettings(
      wakeEnabled: await p.getBool('wakeEnabled') ?? true,
      sensitivity: await p.getDouble('sensitivity') ?? 55,
      silenceSecs: await p.getDouble('silenceSecs') ?? 2.0,
      beep: await p.getBool('beep') ?? true,
      keepAudio: await p.getBool('keepAudio') ?? false,
      overlayEnabled: await p.getBool('overlayEnabled') ?? true,
      engine: await p.getString('engine') ?? engineCloud,
      tidyEnabled: await p.getBool('tidyEnabled') ?? true,
    );
  }

  Future<void> save() async {
    final p = SharedPreferencesAsync();
    await p.setBool('wakeEnabled', wakeEnabled);
    await p.setDouble('sensitivity', sensitivity);
    await p.setDouble('silenceSecs', silenceSecs);
    await p.setBool('beep', beep);
    await p.setBool('keepAudio', keepAudio);
    await p.setBool('overlayEnabled', overlayEnabled);
    await p.setString('engine', engine);
    await p.setBool('tidyEnabled', tidyEnabled);
  }

  String get sensitivityLabel => sensitivity < 34
      ? 'Low'
      : sensitivity < 67
      ? 'Medium'
      : 'High';
}
