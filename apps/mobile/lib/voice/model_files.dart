import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Where the on-device models live. Bundled models are copied out of the
/// APK on first launch (sherpa-onnx needs real file paths); Whisper is
/// downloaded once.
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

  String get whisperDir => '$root/whisper';
  String get whisperEncoder => '$whisperDir/base.en-encoder.int8.onnx';
  String get whisperDecoder => '$whisperDir/base.en-decoder.int8.onnx';
  String get whisperTokens => '$whisperDir/base.en-tokens.txt';
  bool get whisperReady => File('$whisperDir/.complete').existsSync();
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

  static const whisperBaseUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base.en/resolve/main';
  static const whisperFiles = {
    'base.en-encoder.int8.onnx': 29120534,
    'base.en-decoder.int8.onnx': 130669978,
    'base.en-tokens.txt': 835554,
  };
  static int get whisperBytes => whisperFiles.values.reduce((a, b) => a + b);

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

  /// Downloads Whisper base.en (int8). Emits progress from 0 to 1.
  static Stream<double> downloadWhisper(ModelPaths paths) async* {
    final dir = Directory(paths.whisperDir);
    await dir.create(recursive: true);
    final client = http.Client();
    var done = 0;
    try {
      for (final entry in whisperFiles.entries) {
        final target = File('${dir.path}/${entry.key}');
        if (await target.exists() && await target.length() == entry.value) {
          done += entry.value;
          yield done / whisperBytes;
          continue;
        }
        final part = File('${target.path}.part');
        final res = await client.send(
          http.Request('GET', Uri.parse('$whisperBaseUrl/${entry.key}')),
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
              yield done / whisperBytes;
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
