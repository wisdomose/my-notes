// Runs the real voice pipeline on the host against synthesized speech.
// Needs the models from scripts/fetch-models.sh. The Whisper case also needs
// assets/models/whisper/ (the same files the app downloads), else it skips.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hey_notes/voice/model_files.dart';
import 'package:hey_notes/voice/voice_engine.dart';
import 'package:hey_notes/voice/offline_asr.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

const paths = ModelPaths('assets/models');

class Run {
  final states = <EngineState>[];
  bool byWake = false;
  CaptureResult? result;
  bool done = false;
}

Run feed(String wav, {bool whisper = false, bool wake = true}) {
  final audio = so.readWave(wav);
  final engine = VoiceEngine(paths)
    ..wakeEnabled = wake
    ..silenceSecs = 2.0;
  engine.init(loadWhisper: whisper);
  final run = Run();
  engine
    ..onState = (s, {byWake = false}) {
      run.states.add(s);
      if (s == EngineState.capturing) run.byWake = byWake;
    }
    ..onDone = (r) {
      run.result = r;
      run.done = true;
    };
  // 100 ms chunks, like the microphone stream.
  final s = audio.samples;
  for (var i = 0; i < s.length; i += 1600) {
    engine.accept(Float32List.sublistView(s, i, (i + 1600).clamp(0, s.length)));
  }
  engine.dispose();
  return run;
}

/// On a Linux host, the native library lives in the pub cache.
String? hostLibDir() {
  if (!Platform.isLinux) return null;
  final cache =
      Platform.environment['PUB_CACHE'] ??
      '${Platform.environment['HOME']}/.pub-cache';
  final arch = Platform.version.contains('arm64') ? 'aarch64' : 'x64';
  final dirs =
      Directory('$cache/hosted/pub.dev')
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.contains('sherpa_onnx_linux-'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return dirs.isEmpty ? null : '${dirs.last.path}/linux/$arch';
}

void main() {
  setUpAll(() => so.initBindings(hostLibDir()));

  test('wake word starts a capture and silence saves it (streaming model)', () {
    final run = feed('test/fixtures/hey_notes_shopping.wav');
    expect(run.byWake, isTrue, reason: 'should wake on "Hey notes"');
    expect(run.done, isTrue, reason: 'should end after 2 s of silence');
    final text = run.result!.text.toLowerCase();
    // ignore: avoid_print
    print('streaming: ${run.result!.text}');
    expect(text, contains('bread'));
    expect(text, contains('home'));
    expect(text, isNot(startsWith('hey')));
    expect(run.result!.usedWhisper, isFalse);
  });

  test('wakes again for a second note right after the first', () {
    final a = so.readWave('test/fixtures/hey_notes_shopping.wav').samples;
    final audio = Float32List(a.length * 2)
      ..setAll(0, a)
      ..setAll(a.length, a);
    final engine = VoiceEngine(paths)..init(loadWhisper: false);
    final wakes = <bool>[];
    final notes = <String?>[];
    engine.onState = (s, {byWake = false}) {
      if (s == EngineState.capturing) wakes.add(byWake);
    };
    engine.onDone = (r) => notes.add(r?.text);
    for (var i = 0; i < audio.length; i += 1600) {
      engine.accept(
        Float32List.sublistView(audio, i, (i + 1600).clamp(0, audio.length)),
      );
    }
    engine.dispose();
    expect(wakes, [true, true]);
    expect(notes, hasLength(2));
    expect(notes.every((n) => n != null && n.contains('home')), isTrue);
  });

  test('speech without the wake word is ignored', () {
    final run = feed('test/fixtures/no_wake_word.wav');
    expect(run.states, isEmpty);
    expect(run.done, isFalse);
  });

  test('wake word disabled ignores "Hey notes"', () {
    final run = feed('test/fixtures/hey_notes_shopping.wav', wake: false);
    expect(run.states, isEmpty);
  });

  test('Whisper re-transcribes the capture', () {
    final run = feed('test/fixtures/hey_notes_shopping.wav', whisper: true);
    expect(run.done, isTrue);
    // ignore: avoid_print
    print('whisper: ${run.result!.text}');
    expect(run.result!.usedWhisper, isTrue);
    expect(run.result!.text, contains('bread'));
    expect(run.result!.text, endsWith('.'));
  }, skip: paths.whisperReady ? false : 'Whisper model not downloaded');

  test('manual start with no speech cancels after the timeout', () {
    final engine = VoiceEngine(paths)..init(loadWhisper: false);
    CaptureResult? result;
    var done = false;
    engine.onDone = (r) {
      result = r;
      done = true;
    };
    engine.start();
    for (var i = 0; i < 80; i++) {
      engine.accept(Float32List(1600));
    }
    expect(done, isTrue);
    expect(result, isNull);
    expect(engine.state, EngineState.idle);
    engine.dispose();
  });

  test('keyword buffer matches the KWS vocabulary', () {
    final tokens = File(paths.kwsTokens)
        .readAsLinesSync()
        .map((l) => l.split(' ').first)
        .toSet();
    for (final line in VoiceEngine.keywords(55).split('\n')) {
      final pieces = line.split(' ').takeWhile((p) => !p.startsWith(':'));
      for (final p in pieces) {
        expect(tokens, contains(p));
      }
    }
  });

  test('Whisper on its worker isolate keeps this thread free', () async {
    final worker = await OfflineWorker.spawn(
      OfflineModel.whisper,
      paths,
      libDir: hostLibDir(),
    );
    addTearDown(worker.dispose);
    final engine = VoiceEngine(paths)..init(loadWhisper: false);
    addTearDown(engine.dispose);
    engine.transcriber = (segs) =>
        worker.transcribe(segs, VoiceEngine.sampleRate);

    final done = Completer<CaptureResult?>();
    engine.onDone = done.complete;
    // Ticks only if this isolate isn't blocked while Whisper runs.
    var ticks = 0;
    var transcribing = false;
    final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (transcribing) ticks++;
    });
    engine.onState = (s, {byWake = false}) {
      transcribing = s == EngineState.transcribing;
    };

    final s = so.readWave('test/fixtures/hey_notes_shopping.wav').samples;
    for (var i = 0; i < s.length; i += 1600) {
      engine.accept(
        Float32List.sublistView(s, i, (i + 1600).clamp(0, s.length)),
      );
      // Like the mic stream: audio arrives as events, not in one go.
      await Future<void>.delayed(Duration.zero);
    }
    final result = await done.future.timeout(const Duration(seconds: 60));
    timer.cancel();

    // ignore: avoid_print
    print(
      'worker: ${result?.text} '
      '(${worker.lastDuration.inMilliseconds} ms, $ticks ticks)',
    );
    expect(result?.usedWhisper, isTrue);
    expect(result!.text, contains('bread'));
    // Whisper takes far longer than 20 ms; we must have kept ticking.
    expect(ticks, greaterThan(3));
  }, skip: paths.whisperReady ? false : 'Whisper model not downloaded');

  test(
    'Parakeet transcribes on its worker isolate',
    () async {
      final worker = await OfflineWorker.spawn(
        OfflineModel.parakeet,
        paths,
        libDir: hostLibDir(),
      );
      addTearDown(worker.dispose);
      final s = so.readWave('test/fixtures/hey_notes_shopping.wav').samples;
      final text = await worker.transcribe([s], VoiceEngine.sampleRate);
      // ignore: avoid_print
      print('parakeet: $text (${worker.lastDuration.inMilliseconds} ms)');
      expect(text.toLowerCase(), contains('buy bread'));
    },
    skip: paths.isReady(OfflineModel.parakeet)
        ? false
        : 'Parakeet model not downloaded',
  );
}
