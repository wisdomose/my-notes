import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../util/text.dart';
import 'model_files.dart';

enum EngineState { idle, capturing, transcribing }

class CaptureResult {
  CaptureResult({
    required this.text,
    required this.samples,
    required this.byWake,
    required this.usedWhisper,
  });

  final String text;
  final Float32List samples;
  final bool byWake;
  final bool usedWhisper;

  int get durationMs => samples.length * 1000 ~/ VoiceEngine.sampleRate;
}

/// The on-device voice pipeline. Feed it 16 kHz mono audio with [accept]:
///
///   idle ──"Hey Notes"/start()──▶ capturing ──silence/stop()──▶ transcribing
///     ▲                                                              │
///     └──────────────────────── onDone(result) ◀─────────────────────┘
///
/// * idle: the keyword spotter listens for the wake phrase.
/// * capturing: audio is buffered, the streaming model shows live text and
///   the VAD decides when you've stopped talking.
/// * transcribing: Whisper (if downloaded) re-transcribes the speech
///   segments; otherwise the streaming result is used.
///
/// Pure Dart (no Flutter), so it runs in the background service isolate and
/// in host tests.
class VoiceEngine {
  VoiceEngine(this.paths);

  static const sampleRate = 16000;
  static const _vadWindow = 512;
  static const _vadMinSilence = 0.5;
  static const noSpeechTimeoutSecs = 7.0;
  static const maxCaptureSecs = 120.0;

  /// Audio kept from before the wake word. The streaming model drops the
  /// first words if it starts cold mid-speech, so it gets this lead-in.
  static const prerollSecs = 2.0;

  /// What the streaming model makes of the tail of "Hey Notes" in the
  /// pre-roll: "S", "Y NOTES", "HEY NOTE"...
  static final _wakeResidue = RegExp(
    r'^\s*((hey|hay|he|ey|y|s|t|notes?)\s+)+',
    caseSensitive: false,
  );

  final ModelPaths paths;

  bool wakeEnabled = true;
  double silenceSecs = 2.0;
  double _sensitivity = 55;

  void Function(EngineState state, {bool byWake})? onState;
  void Function(String text)? onPartial;
  void Function(double level)? onLevel;

  /// Null result: nothing was said, or the capture was cancelled.
  void Function(CaptureResult? result)? onDone;

  EngineState _state = EngineState.idle;
  EngineState get state => _state;

  late so.KeywordSpotter _kws;
  late so.OnlineStream _kwsStream;
  late so.OnlineRecognizer _asr;
  late so.VoiceActivityDetector _vad;
  so.OfflineRecognizer? _whisper;

  so.OnlineStream? _asrStream;
  final List<Float32List> _chunks = [];
  final List<Float32List> _segments = [];
  final List<double> _vadPending = [];
  final List<Float32List> _preroll = [];
  int _prerollLen = 0;
  int _captured = 0;
  int _lastVoiceAt = 0;
  bool _speechSeen = false;
  bool _byWake = false;
  String _partial = '';

  bool get whisperLoaded => _whisper != null;

  void init({double sensitivity = 55, bool loadWhisper = true}) {
    _sensitivity = sensitivity;
    _createKws();
    _asr = so.OnlineRecognizer(
      so.OnlineRecognizerConfig(
        model: so.OnlineModelConfig(
          transducer: so.OnlineTransducerModelConfig(
            encoder: paths.asrEncoder,
            decoder: paths.asrDecoder,
            joiner: paths.asrJoiner,
          ),
          tokens: paths.asrTokens,
          numThreads: 2,
          debug: false,
        ),
        enableEndpoint: false,
      ),
    );
    _vad = so.VoiceActivityDetector(
      config: so.VadModelConfig(
        sileroVad: so.SileroVadModelConfig(
          model: paths.vad,
          threshold: 0.5,
          minSilenceDuration: _vadMinSilence,
          minSpeechDuration: 0.25,
          windowSize: _vadWindow,
          // Whisper handles at most 30 s per pass.
          maxSpeechDuration: 20,
        ),
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: maxCaptureSecs + 10,
    );
    if (loadWhisper) loadWhisperIfReady();
  }

  /// Wake phrase tokens for the KWS model's BPE vocabulary. "HEY NOTE" is
  /// included because the final S is often soft in Nigerian English.
  static String keywords(double sensitivity) {
    final s = sensitivity.clamp(0, 100) / 100;
    // Lower threshold and higher boost = triggers more easily.
    final threshold = (0.35 - 0.25 * s).toStringAsFixed(3);
    final boost = (1.0 + 2.0 * s).toStringAsFixed(2);
    return [
      '▁HE Y ▁NOT ES :$boost #$threshold @HEY_NOTES',
      '▁HE Y ▁NOT E :$boost #$threshold @HEY_NOTES',
    ].join('\n');
  }

  void _createKws() {
    final buf = keywords(_sensitivity);
    _kws = so.KeywordSpotter(
      so.KeywordSpotterConfig(
        model: so.OnlineModelConfig(
          transducer: so.OnlineTransducerModelConfig(
            encoder: paths.kwsEncoder,
            decoder: paths.kwsDecoder,
            joiner: paths.kwsJoiner,
          ),
          tokens: paths.kwsTokens,
          numThreads: 1,
          debug: false,
        ),
        keywordsBuf: buf,
        keywordsBufSize: utf8.encode(buf).length,
        numTrailingBlanks: 1,
      ),
    );
    _kwsStream = _kws.createStream();
  }

  set sensitivity(double value) {
    if (value == _sensitivity) return;
    _sensitivity = value;
    _kwsStream.free();
    _kws.free();
    _createKws();
  }

  void loadWhisperIfReady() {
    if (_whisper != null || !paths.whisperReady) return;
    _whisper = so.OfflineRecognizer(
      so.OfflineRecognizerConfig(
        model: so.OfflineModelConfig(
          whisper: so.OfflineWhisperModelConfig(
            encoder: paths.whisperEncoder,
            decoder: paths.whisperDecoder,
            language: 'en',
            task: 'transcribe',
          ),
          tokens: paths.whisperTokens,
          numThreads: 4,
          debug: false,
        ),
      ),
    );
  }

  void accept(Float32List samples) {
    switch (_state) {
      case EngineState.idle:
        if (wakeEnabled) _spot(samples);
      case EngineState.capturing:
        _capture(samples);
      case EngineState.transcribing:
        break;
    }
  }

  void _spot(Float32List samples) {
    _preroll.add(samples);
    _prerollLen += samples.length;
    while (_prerollLen - _preroll.first.length >= prerollSecs * sampleRate) {
      _prerollLen -= _preroll.removeAt(0).length;
    }
    _kwsStream.acceptWaveform(samples: samples, sampleRate: sampleRate);
    while (_kws.isReady(_kwsStream)) {
      _kws.decode(_kwsStream);
      if (_kws.getResult(_kwsStream).keyword.isNotEmpty) {
        _kws.reset(_kwsStream);
        start(byWake: true);
        return;
      }
    }
  }

  /// Starts a capture (also called on wake). No-op unless idle.
  void start({bool byWake = false}) {
    if (_state != EngineState.idle) return;
    _byWake = byWake;
    _chunks.clear();
    _segments.clear();
    _vadPending.clear();
    _vad.reset();
    _captured = 0;
    _lastVoiceAt = 0;
    _speechSeen = false;
    _partial = '';
    final asr = _asrStream = _asr.createStream();
    if (byWake) {
      for (final c in _preroll) {
        asr.acceptWaveform(samples: c, sampleRate: sampleRate);
      }
      while (_asr.isReady(asr)) {
        _asr.decode(asr);
      }
    }
    _preroll.clear();
    _prerollLen = 0;
    _setState(EngineState.capturing);
  }

  void _capture(Float32List samples) {
    _chunks.add(samples);
    _captured += samples.length;

    final asr = _asrStream!;
    asr.acceptWaveform(samples: samples, sampleRate: sampleRate);
    while (_asr.isReady(asr)) {
      _asr.decode(asr);
    }
    final text = _streamingText(asr);
    if (text != _partial) {
      _partial = text;
      onPartial?.call(text);
    }

    _vadPending.addAll(samples);
    var offset = 0;
    while (_vadPending.length - offset >= _vadWindow) {
      _vad.acceptWaveform(
        Float32List.fromList(_vadPending.sublist(offset, offset + _vadWindow)),
      );
      offset += _vadWindow;
      if (_vad.isDetected()) {
        _speechSeen = true;
        _lastVoiceAt = _captured - (_vadPending.length - offset);
      }
    }
    _vadPending.removeRange(0, offset);
    _drainSegments();

    onLevel?.call(_rmsLevel(samples));

    final elapsed = _captured / sampleRate;
    // The VAD only reports silence after _vadMinSilence, so count from there.
    final quiet = (_captured - _lastVoiceAt) / sampleRate + _vadMinSilence;
    if (_speechSeen && quiet >= silenceSecs) {
      finish();
    } else if (!_speechSeen && elapsed >= noSpeechTimeoutSecs) {
      cancel();
    } else if (elapsed >= maxCaptureSecs) {
      finish();
    }
  }

  String _streamingText(so.OnlineStream asr) {
    final text = _asr.getResult(asr).text;
    return _byWake ? text.replaceFirst(_wakeResidue, '') : text;
  }

  void _drainSegments() {
    while (!_vad.isEmpty()) {
      _segments.add(_vad.front().samples);
      _vad.pop();
    }
  }

  static double _rmsLevel(Float32List s) {
    if (s.isEmpty) return 0;
    var sum = 0.0;
    for (final v in s) {
      sum += v * v;
    }
    final rms = math.sqrt(sum / s.length);
    // Map roughly -50 dBFS..-10 dBFS to 0..1.
    final db = 20 * math.log(rms + 1e-9) / math.ln10;
    return ((db + 50) / 40).clamp(0.0, 1.0);
  }

  /// Ends the capture now and transcribes it. Calls [onDone] synchronously.
  void finish() {
    if (_state != EngineState.capturing) return;
    _setState(EngineState.transcribing);

    _vad.flush();
    _drainSegments();
    final audio = _concat(_chunks);

    var text = '';
    var usedWhisper = false;
    final whisper = _whisper;
    if (whisper != null && _segments.isNotEmpty) {
      final parts = <String>[];
      for (final seg in _segments) {
        final s = whisper.createStream();
        s.acceptWaveform(samples: seg, sampleRate: sampleRate);
        whisper.decode(s);
        parts.add(whisper.getResult(s).text.trim());
        s.free();
      }
      text = cleanTranscript(parts.join(' '));
      usedWhisper = text.isNotEmpty;
    }

    final asr = _asrStream!;
    if (text.isEmpty) {
      asr.acceptWaveform(
        samples: Float32List(sampleRate ~/ 2),
        sampleRate: sampleRate,
      );
      asr.inputFinished();
      while (_asr.isReady(asr)) {
        _asr.decode(asr);
      }
      text = cleanTranscript(_streamingText(asr));
    }
    asr.free();
    _asrStream = null;
    _chunks.clear();
    _segments.clear();
    _setState(EngineState.idle);

    onDone?.call(
      text.isEmpty
          ? null
          : CaptureResult(
              text: text,
              samples: audio,
              byWake: _byWake,
              usedWhisper: usedWhisper,
            ),
    );
  }

  /// Drops the current capture.
  void cancel() {
    if (_state != EngineState.capturing) return;
    _asrStream?.free();
    _asrStream = null;
    _chunks.clear();
    _segments.clear();
    _vad.reset();
    _setState(EngineState.idle);
    onDone?.call(null);
  }

  void _setState(EngineState s) {
    _state = s;
    onState?.call(s, byWake: _byWake);
  }

  static Float32List _concat(List<Float32List> chunks) {
    final out = Float32List(chunks.fold(0, (n, c) => n + c.length));
    var o = 0;
    for (final c in chunks) {
      out.setAll(o, c);
      o += c.length;
    }
    return out;
  }

  void dispose() {
    _asrStream?.free();
    _kwsStream.free();
    _kws.free();
    _asr.free();
    _vad.free();
    _whisper?.free();
  }
}
