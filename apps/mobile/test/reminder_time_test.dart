import 'package:flutter_test/flutter_test.dart';
import 'package:hey_notes/util/reminder_time.dart';

void main() {
  test('localNow has the offset and the weekday', () {
    final s = localNow(DateTime(2026, 10, 6, 14, 5, 9));
    expect(
      s,
      matches(RegExp(r'^2026-10-06T14:05:09[+-]\d\d:\d\d \(Tuesday\)$')),
    );
  });

  test('checkReminderAt keeps future times within two years', () {
    final now = DateTime.utc(2026, 10, 6, 13, 5);
    expect(
      checkReminderAt('2026-10-12T09:00:00+01:00', now),
      DateTime.utc(2026, 10, 12, 8).toLocal(),
    );
    expect(checkReminderAt('2026-10-06T13:00:00Z', now), isNull); // past
    expect(checkReminderAt('2029-01-01T09:00:00Z', now), isNull); // too far
    expect(checkReminderAt('next Monday', now), isNull);
  });

  test('formatReminder', () {
    final now = DateTime(2026, 10, 6);
    expect(
      formatReminder(DateTime(2026, 10, 7, 9), now: now),
      'Wed 7 Oct, 09:00',
    );
    expect(
      formatReminder(DateTime(2027, 1, 4, 20, 30), now: now),
      'Mon 4 Jan 2027, 20:30',
    );
  });
}
