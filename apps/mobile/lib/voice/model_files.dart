import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// The optional on-device transcription models, downloaded once from
/// Hugging Face (int8 ONNX exports for sherpa-onnx).
enum OfflineModel {
  whisper(
    label: 'Whisper',
    dir: 'whisper',
    baseUrl: 'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base.en/resolve/main',
    files: {
      'base.en-encoder.int8.onnx': 29120534,
      'base.en-decoder.int8.onnx': 130669978,
      'base.en-tokens.txt': 835554,
    },
  ),

  /// NVIDIA Parakeet TDT 0.6B v2 (CC-BY-4.0). Large: loaded only while
  /// selected.
  parakeet(
    label: 'Parakeet',
    dir: 'parakeet',
    baseUrl: 'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/resolve/main',
    files: {
      'encoder.int8.onnx': 652184296,
      'decoder.int8.onnx': 7257753,
      'joiner.int8.onnx': 1739080,
      'tokens.txt': 9384,
    },
  );

  const OfflineModel({
    required this.label,
    required this.dir,
    required this.baseUrl,
    required this.files,
  });

  final String label;
  final String dir;
  final String baseUrl;

  /// File name → exact size in bytes (checked after download).
  final Map<String, int> files;

  int get bytes => files.values.reduce((a, b) => a + b);
  String get sizeLabel => '${(bytes / 1e6).round()} MB';
}

/// Where the on-device models live. Bundled models are copied out of the
/// APK on first launch (sherpa-onnx needs real file paths); the
/// [OfflineModel]s are downloaded once.
class ModelPaths {
  const ModelPaths(this.root);

  final String root;

  String get kwsEncoder => '$root/kws/encoder.onnx';
  String get kwsDecoder => '$root/kws/decoder.onnx';
  String get kwsJoiner => '$root/kws/joiner.onnx';
  String get kwsTokens => '$root/kws/tokens.txt';

  String get asrEncoder => '$root/asr/encoder.onnx';
  String get asrDecoder => '$root/asr/decoder.onnx';
  String get asrJoiner => '$root/asr/joiner.onnx';
  String get asrTokens => '$root/asr/tokens.txt';

  String get vad => '$root/silero_vad.onnx';

  String dirOf(OfflineModel m) => '$root/${m.dir}';
  bool isReady(OfflineModel m) => File('${dirOf(m)}/.complete').existsSync();

  String get whisperDir => dirOf(OfflineModel.whisper);
  String get whisperEncoder => '$whisperDir/base.en-encoder.int8.onnx';
  String get whisperDecoder => '$whisperDir/base.en-decoder.int8.onnx';
  String get whisperTokens => '$whisperDir/base.en-tokens.txt';
  bool get whisperReady => isReady(OfflineModel.whisper);

  String get parakeetDir => dirOf(OfflineModel.parakeet);
  String get parakeetEncoder => '$parakeetDir/encoder.int8.onnx';
  String get parakeetDecoder => '$parakeetDir/decoder.int8.onnx';
  String get parakeetJoiner => '$parakeetDir/joiner.int8.onnx';
  String get parakeetTokens => '$parakeetDir/tokens.txt';
}

class ModelFiles {
  static const _bundleVersion = 'bundled-v1';
  static const _bundled = [
    'kws/encoder.onnx',
    'kws/decoder.onnx',
    'kws/joiner.onnx',
    'kws/tokens.txt',
    'asr/encoder.onnx',
    'asr/decoder.onnx',
    'asr/joiner.onnx',
    'asr/tokens.txt',
    'silero_vad.onnx',
  ];

  static Future<ModelPaths> paths() async =>
      ModelPaths('${(await getApplicationSupportDirectory()).path}/models');

  /// Copies bundled models out of the APK if this version hasn't yet.
  static Future<ModelPaths> ensureBundled() async {
    final paths = await ModelFiles.paths();
    final marker = File('${paths.root}/.$_bundleVersion');
    if (await marker.exists()) return paths;
    for (final name in _bundled) {
      final data = await rootBundle.load('assets/models/$name');
      final out = File('${paths.root}/$name');
      await out.parent.create(recursive: true);
      await out.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    await marker.writeAsString('ok');
    return paths;
  }

  /// Downloads [model] (resumable per file). Emits progress from 0 to 1.
  static Stream<double> download(ModelPaths paths, OfflineModel model) async* {
    final dir = Directory(paths.dirOf(model));
    final total = model.bytes;
    await dir.create(recursive: true);
    final client = http.Client();
    var done = 0;
    try {
      for (final entry in model.files.entries) {
        final target = File('${dir.path}/${entry.key}');
        if (await target.exists() && await target.length() == entry.value) {
          done += entry.value;
          yield done / total;
          continue;
        }
        final part = File('${target.path}.part');
        final res = await client.send(
          http.Request('GET', Uri.parse('${model.baseUrl}/${entry.key}')),
        );
        if (res.statusCode != 200) {
          throw HttpException('HTTP ${res.statusCode} for ${entry.key}');
        }
        final sink = part.openWrite();
        var lastYield = 0;
        try {
          await for (final chunk in res.stream) {
            sink.add(chunk);
            done += chunk.length;
            if (done - lastYield > 512 * 1024) {
              lastYield = done;
              yield done / total;
            }
          }
        } finally {
          await sink.close();
        }
        if (await part.length() != entry.value) {
          await part.delete();
          throw const HttpException('Download was incomplete, try again');
        }
        await part.rename(target.path);
      }
      await File('${dir.path}/.complete').writeAsString('ok');
      yield 1;
    } finally {
      client.close();
    }
  }
}
