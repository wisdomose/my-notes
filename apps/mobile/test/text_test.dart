import 'package:flutter_test/flutter_test.dart';
import 'package:hey_notes/util/text.dart';

void main() {
  group('cleanTranscript', () {
    test('sentence-cases ALL CAPS streaming output', () {
      expect(
        cleanTranscript('BUY BREAD AND I WILL CALL MAMA'),
        'Buy bread and I will call mama.',
      );
    });

    test('strips a leading wake phrase', () {
      expect(cleanTranscript('Hey notes, buy bread.'), 'Buy bread.');
      expect(cleanTranscript('HEY NOTE BUY BREAD'), 'Buy bread.');
    });

    test('keeps notes that only mention notes', () {
      expect(
        cleanTranscript('A note about the meeting'),
        'A note about the meeting.',
      );
    });

    test('drops Whisper non-speech tags', () {
      expect(cleanTranscript('[BLANK_AUDIO]'), '');
      expect(
        cleanTranscript(' (music) Call the landlord.'),
        'Call the landlord.',
      );
    });
  });

  group('makeTitle', () {
    test('uses the first words of the first sentence', () {
      expect(
        makeTitle('Buy plantain, eggs and bread on the way home.'),
        'Buy plantain, eggs and bread on…',
      );
      expect(makeTitle('Call mama. Then the landlord.'), 'Call mama');
    });

    test('handles empty text', () {
      expect(makeTitle('  '), 'Untitled note');
    });
  });

  test('dayLabel', () {
    final now = DateTime(2026, 10, 4, 9);
    expect(dayLabel(DateTime(2026, 10, 4, 1), now), 'TODAY');
    expect(dayLabel(DateTime(2026, 10, 3, 23), now), 'YESTERDAY');
    expect(dayLabel(DateTime(2026, 10, 1), now), 'THU 1 OCT');
  });

  test('formatDuration', () {
    expect(formatDuration(9400), '0:09');
    expect(formatDuration(75000), '1:15');
  });
}
