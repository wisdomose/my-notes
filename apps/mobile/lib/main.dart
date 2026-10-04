import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'data/notes_db.dart';
import 'data/settings.dart';
import 'theme.dart';
import 'ui/home_screen.dart';
import 'voice/model_files.dart';
import 'voice/voice_controller.dart';
import 'voice/whisper_download.dart';

/// App-wide services, created once at startup.
class Services {
  Services._(this.db, this.settings, this.voice, this.whisper);

  final NotesDb db;
  final AppSettings settings;
  final VoiceController voice;
  final WhisperDownload whisper;

  static late final Services instance;

  static Future<void> init() async {
    final db = await NotesDb.open();
    final settings = await AppSettings.load();
    final paths = await ModelFiles.ensureBundled();
    final voice = VoiceController(settings)..init();
    final whisper = WhisperDownload(paths, onReady: voice.settingsChanged);
    instance = Services._(db, settings, voice, whisper);
  }
}

Services get services => Services.instance;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: C.bg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  await Services.init();
  runApp(const HeyNotesApp());
}

class HeyNotesApp extends StatelessWidget {
  const HeyNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        title: 'Hey Notes',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const HomeScreen(),
      ),
    );
  }
}
