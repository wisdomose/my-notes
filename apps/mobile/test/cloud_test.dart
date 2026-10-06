import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hey_notes/voice/cloud.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import 'voice_engine_test.dart' show hostLibDir;

void main() {
  test('joins segments with a short gap and encodes 16-bit WAV', () {
    final a = Float32List.fromList([0.5, -0.5]);
    final b = Float32List.fromList([1.0]);
    final joined = CloudTranscriber.joinSegments([a, b], 10); // 10 Hz: 3 gap
    expect(joined, [0.5, -0.5, 0, 0, 0, 1.0]);

    final wav = CloudTranscriber.encodeWav(joined, 16000);
    final v = ByteData.sublistView(wav);
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
    expect(v.getUint32(24, Endian.little), 16000);
    expect(v.getUint32(40, Endian.little), joined.length * 2);
    expect(v.getInt16(44, Endian.little), 16384); // 0.5 * 32767, rounded
    expect(v.getInt16(46, Endian.little), -16384);
  });

  test('the WAV it sends decodes back to the same audio', () {
    so.initBindings(hostLibDir());
    final samples = Float32List.fromList(
      List.generate(1600, (i) => (i % 40 - 20) / 40),
    );
    final file = File('${Directory.systemTemp.path}/cloud_test.wav')
      ..writeAsBytesSync(CloudTranscriber.encodeWav(samples, 16000));
    final back = so.readWave(file.path);
    expect(back.sampleRate, 16000);
    expect(back.samples.length, samples.length);
    expect((back.samples[123] - samples[123]).abs(), lessThan(1e-3));
  });

  group('against a fake API', () {
    late HttpServer server;
    late List<String> seen;
    var reply = (200, '{"text":"Buy bread."}');

    setUp(() async {
      seen = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        // latin1: the body holds binary WAV bytes.
        final body = await latin1.decoder.bind(req).join();
        seen
          ..add('${req.method} ${req.uri.path}')
          ..add(req.headers.contentType?.mimeType ?? '')
          ..add(body);
        req.response
          ..statusCode = reply.$1
          ..headers.contentType = ContentType.json
          ..write(reply.$2);
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    CloudTranscriber client() =>
        CloudTranscriber(baseUrl: 'http://127.0.0.1:${server.port}/');

    test('posts multipart audio + language and returns the text', () async {
      reply = (200, '{"text":"Buy bread.","fileId":null}');
      final text = await client().transcribe(
        [Float32List(1600)],
        16000,
        language: 'pcm',
      );
      expect(text, 'Buy bread.');
      expect(seen[0], 'POST /v1/transcribe');
      expect(seen[1], 'multipart/form-data');
      expect(seen[2], contains('name="audio"; filename="note.wav"'));
      expect(seen[2], contains('name="language"'));
      expect(seen[2], contains('pcm'));
      expect(seen[2], contains('RIFF'));
    });

    test('tidy posts JSON and returns title and text', () async {
      reply = (
        200,
        '{"title":"Call Peter about the car","text":"Call Peter."}',
      );
      final t = await client().tidy('call call John no wait call Peter');
      expect(t.title, 'Call Peter about the car');
      expect(t.text, 'Call Peter.');
      expect(seen[0], 'POST /v1/tidy');
      expect(seen[1], 'application/json');
      expect(jsonDecode(seen[2]), {
        'text': 'call call John no wait call Peter',
      });
    });

    test('tidy errors become CloudError', () async {
      reply = (503, '{"error":"Tidying isn\u0027t configured"}');
      await expectLater(client().tidy('x'), throwsA(isA<CloudError>()));
    });

    test('turns API errors into CloudError', () async {
      reply = (429, '{"error":"Too many requests, slow down"}');
      await expectLater(
        client().transcribe([Float32List(1600)], 16000),
        throwsA(
          isA<CloudError>().having(
            (e) => e.message,
            'message',
            'HTTP 429: Too many requests, slow down',
          ),
        ),
      );
    });
  });

  // Uses Intron credits: run with HEY_NOTES_LIVE_API=1.
  test(
    'live API transcribes the fixture',
    () async {
      so.initBindings(hostLibDir());
      final audio = so.readWave('test/fixtures/hey_notes_shopping.wav');
      final text = await CloudTranscriber().transcribe([
        audio.samples,
      ], audio.sampleRate);
      // ignore: avoid_print
      print('live: $text');
      expect(text.toLowerCase(), contains('bread'));
    },
    skip: Platform.environment['HEY_NOTES_LIVE_API'] == '1'
        ? false
        : 'set HEY_NOTES_LIVE_API=1 to call the real API',
  );
}
