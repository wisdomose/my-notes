import 'package:flutter/foundation.dart';

import 'model_files.dart';

enum WhisperStatus { missing, downloading, ready, failed }

/// Downloads the Whisper model once; afterwards everything is offline.
class WhisperDownload extends ChangeNotifier {
  WhisperDownload(this.paths, {required this.onReady}) {
    status = paths.whisperReady ? WhisperStatus.ready : WhisperStatus.missing;
  }

  final ModelPaths paths;
  final VoidCallback onReady;

  late WhisperStatus status;
  double progress = 0;
  String? error;

  static String get sizeLabel =>
      '${(ModelFiles.whisperBytes / 1e6).round()} MB';

  Future<void> start() async {
    if (status == WhisperStatus.downloading || status == WhisperStatus.ready) {
      return;
    }
    status = WhisperStatus.downloading;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      await for (final p in ModelFiles.downloadWhisper(paths)) {
        progress = p;
        notifyListeners();
      }
      status = WhisperStatus.ready;
      onReady();
    } catch (e) {
      status = WhisperStatus.failed;
      error = 'Download failed. Check your connection and try again.';
    }
    notifyListeners();
  }
}
