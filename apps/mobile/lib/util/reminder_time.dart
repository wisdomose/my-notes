/// Times for "remind me …" notes. The API works out *when* from the words
/// and the phone's clock; these helpers format the clock and check the
/// answer.
library;

/// The note asked for a reminder but its time couldn't be worked out
/// (stored as the note's tidy error, so Retry tries again).
const reminderUnclear = 'Couldn’t work out when to remind you';

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// "2026-10-06T14:05:00+01:00 (Tuesday)": local time with its UTC offset.
String localNow(DateTime t) {
  final off = t.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final m = off.inMinutes.abs();
  return '${t.year}-${_two(t.month)}-${_two(t.day)}'
      'T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}'
      '$sign${_two(m ~/ 60)}:${_two(m % 60)} (${_weekdays[t.weekday - 1]})';
}

/// The reminder time from the API, or null when it isn't a usable time:
/// unparseable, already past, or more than two years away.
DateTime? checkReminderAt(String at, DateTime now) {
  final t = DateTime.tryParse(at);
  if (t == null) return null;
  // Without an offset the time would be read as the phone's; fine.
  if (!t.isAfter(now)) return null;
  if (t.isAfter(now.add(const Duration(days: 731)))) return null;
  return t.toLocal();
}

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Tue 7 Oct, 09:00" (the year only when it isn't this one).
String formatReminder(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final year = t.year == n.year ? '' : ' ${t.year}';
  return '${_days[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}$year, '
      '${_two(t.hour)}:${_two(t.minute)}';
}
