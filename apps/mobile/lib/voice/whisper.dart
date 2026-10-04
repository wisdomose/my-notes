import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import 'model_files.dart';

/// Whisper threads. Android runs background apps on the small cores, so
/// leave some free for the overlay and the rest of the phone.
int whisperThreads() => Platform.numberOfProcessors >= 8 ? 3 : 2;

so.OfflineRecognizer createWhisper(ModelPaths paths, {int? threads}) =>
    so.OfflineRecognizer(
      so.OfflineRecognizerConfig(
        model: so.OfflineModelConfig(
          whisper: so.OfflineWhisperModelConfig(
            encoder: paths.whisperEncoder,
            decoder: paths.whisperDecoder,
            language: 'en',
            task: 'transcribe',
          ),
          tokens: paths.whisperTokens,
          numThreads: threads ?? whisperThreads(),
          debug: false,
        ),
      ),
    );

/// Transcribes each speech segment (each under 30 s) and joins the text.
String whisperTranscribe(
  so.OfflineRecognizer whisper,
  List<Float32List> segments,
  int sampleRate,
) {
  final parts = <String>[];
  for (final seg in segments) {
    final s = whisper.createStream();
    s.acceptWaveform(samples: seg, sampleRate: sampleRate);
    whisper.decode(s);
    parts.add(whisper.getResult(s).text.trim());
    s.free();
  }
  return parts.join(' ');
}

/// Whisper on its own long-lived isolate (thread), loaded once. Whisper
/// blocks whatever thread runs it for seconds; here that's not the voice
/// service, which keeps the overlay, notification and microphone going.
class WhisperWorker {
  WhisperWorker._(this._isolate, this._requests, this._replies);

  final Isolate _isolate;
  final SendPort _requests;
  final ReceivePort _replies;
  final _pending = <int, Completer<String>>{};
  int _nextId = 0;

  /// Time the last [transcribe] took inside the worker.
  Duration lastDuration = Duration.zero;

  /// Starts the isolate and loads the model. [libDir] is only needed off
  /// Android (host tests), where sherpa-onnx's library isn't on the path.
  static Future<WhisperWorker> spawn(ModelPaths paths, {String? libDir}) async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(_main, [
      replies.sendPort,
      paths.root,
      libDir,
      whisperThreads(),
    ], debugName: 'whisper');
    final first = Completer<SendPort>();
    late final WhisperWorker worker;
    replies.listen((msg) {
      if (!first.isCompleted) {
        if (msg is SendPort) {
          first.complete(msg);
        } else {
          first.completeError(StateError('Whisper failed to load: $msg'));
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
      worker = WhisperWorker._(isolate, await first.future, replies);
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
      c.completeError(StateError('Whisper worker stopped'));
    }
    _pending.clear();
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
  }

  static void _main(List<Object?> args) {
    final [
      reply as SendPort,
      root as String,
      libDir as String?,
      threads as int,
    ] = args;
    final so.OfflineRecognizer whisper;
    try {
      so.initBindings(libDir);
      whisper = createWhisper(ModelPaths(root), threads: threads);
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
        final text = whisperTranscribe(whisper, segments, rate);
        reply.send([id, true, text, sw.elapsedMilliseconds]);
      } catch (e) {
        reply.send([id, false, '$e', sw.elapsedMilliseconds]);
      }
    });
  }
}
