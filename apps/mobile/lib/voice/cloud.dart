import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// The Hey Notes API (apps/api), which transcribes with Intron Sahara.
/// Override with `--dart-define=API_BASE_URL=...`.
const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://hey-notes-api.80.241.218.79.sslip.io',
);

class CloudError implements Exception {
  CloudError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Sends speech to `POST /v1/transcribe` and returns the text.
class CloudTranscriber {
  CloudTranscriber({String baseUrl = apiBaseUrl, http.Client? client})
    : _base = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl,
      _client = client ?? http.Client();

  final String _base;
  final http.Client _client;

  /// Speech segments joined with this much silence between them: only the
  /// speech is uploaded, not the pauses around it.
  static const gapSeconds = 0.3;

  Future<String> transcribe(
    List<Float32List> segments,
    int sampleRate, {
    String language = 'en',
  }) async {
    final wav = encodeWav(joinSegments(segments, sampleRate), sampleRate);
    final req = http.MultipartRequest('POST', Uri.parse('$_base/v1/transcribe'))
      ..fields['language'] = language
      ..files.add(
        http.MultipartFile.fromBytes('audio', wav, filename: 'note.wav'),
      );
    final res = await http.Response.fromStream(await _client.send(req));
    Map<String, Object?> body;
    try {
      body = jsonDecode(res.body) as Map<String, Object?>;
    } catch (_) {
      body = const {};
    }
    if (res.statusCode != 200) {
      throw CloudError(
        'HTTP ${res.statusCode}: ${body['error'] ?? 'request failed'}',
      );
    }
    final text = body['text'];
    if (text is! String) throw CloudError('unexpected response');
    return text;
  }

  void close() => _client.close();

  static Float32List joinSegments(List<Float32List> segments, int rate) {
    final gap = (gapSeconds * rate).round();
    final total =
        segments.fold(0, (n, s) => n + s.length) +
        gap * (segments.length - 1).clamp(0, segments.length);
    final out = Float32List(total);
    var o = 0;
    for (var i = 0; i < segments.length; i++) {
      if (i > 0) o += gap;
      out.setAll(o, segments[i]);
      o += segments[i].length;
    }
    return out;
  }

  /// 16-bit PCM mono WAV.
  static Uint8List encodeWav(Float32List samples, int rate) {
    final data = samples.length * 2;
    final b = ByteData(44 + data);
    void ascii(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    b.setUint32(4, 36 + data, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    b.setUint32(16, 16, Endian.little); // fmt chunk size
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, rate, Endian.little);
    b.setUint32(28, rate * 2, Endian.little); // byte rate
    b.setUint16(32, 2, Endian.little); // block align
    b.setUint16(34, 16, Endian.little); // bits per sample
    ascii(36, 'data');
    b.setUint32(40, data, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
      b.setInt16(44 + i * 2, v, Endian.little);
    }
    return b.buffer.asUint8List();
  }
}
