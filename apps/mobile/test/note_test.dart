import 'package:flutter_test/flutter_test.dart';
import 'package:hey_notes/data/note.dart';

void main() {
  test('reminder and back-online fields survive the database round trip', () {
    final at = DateTime(2026, 10, 7, 9);
    final note = Note(
      id: 1,
      title: 'Call the bank',
      body: 'Remind me tomorrow at 9 to call the bank.',
      createdAt: DateTime(2026, 10, 6, 14, 5),
      tags: const ['money'],
      remindAt: at,
      autoRetries: 2,
      retriedOnline: true,
    );
    final back = Note.fromMap(note.toMap());
    expect(back.remindAt, at);
    expect(back.autoRetries, 2);
    expect(back.retriedOnline, isTrue);
    expect(back.tags, ['money']);
    expect(back.copyWith(remindAt: () => null).remindAt, isNull);
    expect(back.withoutAudio().retriedOnline, isTrue);
  });

  test('old rows without the new columns read as defaults', () {
    final n = Note.fromMap({
      'id': 2,
      'title': 't',
      'body': 'b',
      'created_at': 0,
    });
    expect(n.remindAt, isNull);
    expect(n.autoRetries, 0);
    expect(n.retriedOnline, isFalse);
  });
}
