import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum ModelKind { whisper, nemoTransducer }

/// The optional on-device transcription models, downloaded once from
/// Hugging Face (int8 ONNX exports for sherpa-onnx). Each is loaded only
/// while it transcribes a note, then unloaded.
enum OfflineModel {
  whisper(
    label: 'Whisper',
    dir: 'whisper',
    kind: ModelKind.whisper,
    baseUrl: 'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base.en/resolve/main',
    encoder: 'base.en-encoder.int8.onnx',
    decoder: 'base.en-decoder.int8.onnx',
    tokens: 'base.en-tokens.txt',
    files: {
      'base.en-encoder.int8.onnx': 29120534,
      'base.en-decoder.int8.onnx': 130669978,
      'base.en-tokens.txt': 835554,
    },
    runtimeBytes: 400 * mb,
    minDeviceBytes: 3 * gb,
  ),

  /// NVIDIA Parakeet TDT 0.6B v2 (CC-BY-4.0).
  parakeet(
    label: 'Parakeet',
    dir: 'parakeet',
    kind: ModelKind.nemoTransducer,
    baseUrl: 'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/resolve/main',
    encoder: 'encoder.int8.onnx',
    decoder: 'decoder.int8.onnx',
    joiner: 'joiner.int8.onnx',
    tokens: 'tokens.txt',
    files: {
      'encoder.int8.onnx': 652184296,
      'decoder.int8.onnx': 7257753,
      'joiner.int8.onnx': 1739080,
      'tokens.txt': 9384,
    },
    runtimeBytes: 1000 * mb,
    minDeviceBytes: 6 * gb,
  ),

  /// OpenAI Whisper large-v3-turbo (MIT).
  whisperTurbo(
    label: 'Whisper Turbo',
    dir: 'whisper-turbo',
    kind: ModelKind.whisper,
    baseUrl: 'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-turbo/resolve/main',
    encoder: 'turbo-encoder.int8.onnx',
    decoder: 'turbo-decoder.int8.onnx',
    tokens: 'turbo-tokens.txt',
    files: {
      'turbo-encoder.int8.onnx': 674716297,
      'turbo-decoder.int8.onnx': 361080764,
      'turbo-tokens.txt': 816730,
    },
    runtimeBytes: 1500 * mb,
    minDeviceBytes: 8 * gb,
  ),

  /// OpenAI Whisper large-v3 (MIT).
  whisperLarge(
    label: 'Whisper Large',
    dir: 'whisper-large-v3',
    kind: ModelKind.whisper,
    baseUrl: 'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-large-v3/resolve/main',
    encoder: 'large-v3-encoder.int8.onnx',
    decoder: 'large-v3-decoder.int8.onnx',
    tokens: 'large-v3-tokens.txt',
    files: {
      'large-v3-encoder.int8.onnx': 766671985,
      'large-v3-decoder.int8.onnx': 1008265203,
      'large-v3-tokens.txt': 816730,
    },
    runtimeBytes: 2500 * mb,
    minDeviceBytes: 12 * gb,
  );

  const OfflineModel({
    required this.label,
    required this.dir,
    required this.kind,
    required this.baseUrl,
    required this.encoder,
    required this.decoder,
    required this.tokens,
    required this.files,
    required this.runtimeBytes,
    required this.minDeviceBytes,
    this.joiner,
  });

  final String label;
  final String dir;
  final ModelKind kind;
  final String baseUrl;
  final String encoder;
  final String decoder;
  final String? joiner;
  final String tokens;

  /// File name → exact size in bytes (checked after download).
  final Map<String, int> files;

  /// Memory it needs while loaded (checked against free memory first).
  final int runtimeBytes;

  /// Smallest phone it's offered on, by nominal RAM (a "6 GB" phone reports
  /// a bit less, so the check allows 10% slack).
  final int minDeviceBytes;

  int get bytes => files.values.reduce((a, b) => a + b);
  String get sizeLabel => bytes >= gb
      ? '${(bytes / gb).toStringAsFixed(1)} GB'
      : '${(bytes / mb).round()} MB';

  bool supportsDevice(int totalMemoryBytes) =>
      totalMemoryBytes >= minDeviceBytes * 0.9;

  String get minDeviceLabel => '${(minDeviceBytes / gb).round()} GB';
}

const mb = 1000 * 1000;
const gb = 1000 * mb;

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

  String fileOf(OfflineModel m, String name) => '${dirOf(m)}/$name';
  bool get whisperReady => isReady(OfflineModel.whisper);
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
