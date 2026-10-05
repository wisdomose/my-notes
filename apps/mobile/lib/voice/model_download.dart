import 'package:flutter/foundation.dart';

import 'model_files.dart';

enum ModelStatus { missing, downloading, ready, failed }

/// Downloads one on-device model once; afterwards it works offline.
class ModelDownload extends ChangeNotifier {
  ModelDownload(this.paths, this.model, {required this.onReady}) {
    status = paths.isReady(model) ? ModelStatus.ready : ModelStatus.missing;
  }

  final ModelPaths paths;
  final OfflineModel model;
  final VoidCallback onReady;

  late ModelStatus status;
  double progress = 0;

  Future<void> start() async {
    if (status == ModelStatus.downloading || status == ModelStatus.ready) {
      return;
    }
    status = ModelStatus.downloading;
    progress = 0;
    notifyListeners();
    try {
      await for (final p in ModelFiles.download(paths, model)) {
        progress = p;
        notifyListeners();
      }
      status = ModelStatus.ready;
      onReady();
    } catch (e) {
      status = ModelStatus.failed;
    }
    notifyListeners();
  }
}
