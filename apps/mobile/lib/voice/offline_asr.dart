import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import 'model_files.dart';

/// Threads for an on-device model. Android runs background apps on the
/// small cores, so leave some free for the overlay and the rest of the phone.
int offlineThreads() => Platform.numberOfProcessors >= 8 ? 3 : 2;

so.OfflineRecognizer createOfflineRecognizer(
  OfflineModel model,
  ModelPaths paths, {
  int? threads,
}) {
  final n = threads ?? offlineThreads();
  final config = switch (model) {
    OfflineModel.whisper => so.OfflineModelConfig(
      whisper: so.OfflineWhisperModelConfig(
        encoder: paths.whisperEncoder,
        decoder: paths.whisperDecoder,
        language: 'en',
        task: 'transcribe',
      ),
      tokens: paths.whisperTokens,
      numThreads: n,
      debug: false,
    ),
    OfflineModel.parakeet => so.OfflineModelConfig(
      transducer: so.OfflineTransducerModelConfig(
        encoder: paths.parakeetEncoder,
        decoder: paths.parakeetDecoder,
        joiner: paths.parakeetJoiner,
      ),
      modelType: 'nemo_transducer',
      tokens: paths.parakeetTokens,
      numThreads: n,
      debug: false,
    ),
  };
  return so.OfflineRecognizer(so.OfflineRecognizerConfig(model: config));
}

/// Transcribes each speech segment (each under 30 s) and joins the text.
String offlineTranscribe(
  so.OfflineRecognizer recognizer,
  List<Float32List> segments,
  int sampleRate,
) {
  final parts = <String>[];
  for (final seg in segments) {
    final s = recognizer.createStream();
    s.acceptWaveform(samples: seg, sampleRate: sampleRate);
    recognizer.decode(s);
    parts.add(recognizer.getResult(s).text.trim());
    s.free();
  }
  return parts.join(' ');
}

/// An on-device model on its own long-lived isolate (thread), loaded once.
/// Transcription blocks whatever thread runs it for seconds; here that's
/// not the voice service, which keeps the overlay, notification and
/// microphone going.
class OfflineWorker {
  OfflineWorker._(this.model, this._isolate, this._requests, this._replies);

  final OfflineModel model;
  final Isolate _isolate;
  final SendPort _requests;
  final ReceivePort _replies;
  final _pending = <int, Completer<String>>{};
  int _nextId = 0;

  /// Time the last [transcribe] took inside the worker.
  Duration lastDuration = Duration.zero;

  /// Starts the isolate and loads the model. [libDir] is only needed off
  /// Android (host tests), where sherpa-onnx's library isn't on the path.
  static Future<OfflineWorker> spawn(
    OfflineModel model,
    ModelPaths paths, {
    String? libDir,
  }) async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(_main, [
      replies.sendPort,
      model.name,
      paths.root,
      libDir,
      offlineThreads(),
    ], debugName: model.name);
    final first = Completer<SendPort>();
    late final OfflineWorker worker;
    replies.listen((msg) {
      if (!first.isCompleted) {
        if (msg is SendPort) {
          first.complete(msg);
        } else {
          first.completeError(
            StateError('${model.label} failed to load: $msg'),
          );
        }
        return;
      }
      final [id as int, ok as bool, value as String, ms as int] =
          msg as List<Object?>;
      worker.lastDuration = Duration(milliseconds: ms);
      final c = worker._pending.remove(id);
      if (ok) {
        c?.complete(value);
      } else {
        c?.completeError(StateError(value));
      }
    });
    try {
      worker = OfflineWorker._(model, isolate, await first.future, replies);
      return worker;
    } catch (_) {
      isolate.kill();
      replies.close();
      rethrow;
    }
  }

  Future<String> transcribe(List<Float32List> segments, int sampleRate) {
    final id = _nextId++;
    final c = _pending[id] = Completer<String>();
    _requests.send([
      id,
      sampleRate,
      [
        for (final s in segments) TransferableTypedData.fromList([s]),
      ],
    ]);
    return c.future;
  }

  void dispose() {
    for (final c in _pending.values) {
      c.completeError(StateError('${model.label} worker stopped'));
    }
    _pending.clear();
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
  }

  static void _main(List<Object?> args) {
    final [
      reply as SendPort,
      name as String,
      root as String,
      libDir as String?,
      threads as int,
    ] = args;
    final so.OfflineRecognizer recognizer;
    try {
      so.initBindings(libDir);
      recognizer = createOfflineRecognizer(
        OfflineModel.values.byName(name),
        ModelPaths(root),
        threads: threads,
      );
    } catch (e) {
      reply.send('$e');
      return;
    }
    final requests = ReceivePort();
    reply.send(requests.sendPort);
    requests.listen((msg) {
      final [id as int, rate as int, data as List<Object?>] =
          msg as List<Object?>;
      final sw = Stopwatch()..start();
      try {
        final segments = [
          for (final t in data.cast<TransferableTypedData>())
            t.materialize().asFloat32List(),
        ];
        final text = offlineTranscribe(recognizer, segments, rate);
        reply.send([id, true, text, sw.elapsedMilliseconds]);
      } catch (e) {
        reply.send([id, false, '$e', sw.elapsedMilliseconds]);
      }
    });
  }
}
