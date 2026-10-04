/// Text helpers for turning raw transcripts into notes.
library;

final _wakePrefix = RegExp(
  r'^\s*(hey|hay|hi|ey)[\s,]+notes?\b[\s,.!:-]*',
  caseSensitive: false,
);
final _bracketed = RegExp(r'[\[(][^\])]*[\])]');

/// Cleans a transcript from either the streaming model (ALL CAPS, no
/// punctuation) or Whisper (cased, punctuated, sometimes "[BLANK_AUDIO]").
String cleanTranscript(String raw) {
  var t = raw
      .replaceAll(_bracketed, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  t = t.replaceFirst(_wakePrefix, '').trim();
  if (t.isEmpty || !RegExp(r'[A-Za-z0-9]').hasMatch(t)) return '';

  if (t == t.toUpperCase()) {
    t = t.toLowerCase().replaceAllMapped(
      RegExp(r"\bi\b(?='|\s|$)"),
      (_) => 'I',
    );
  }
  t = t[0].toUpperCase() + t.substring(1);
  if (!RegExp(r'[.!?]$').hasMatch(t)) t = '$t.';
  return t;
}

/// A short title from the first words of the note.
String makeTitle(String body, {int maxWords = 6}) {
  final clean = body.trim();
  if (clean.isEmpty) return 'Untitled note';
  final first = clean.split(RegExp(r'(?<=[.!?])\s+')).first;
  final words = first.split(RegExp(r'\s+'));
  var t = words.take(maxWords).join(' ').replaceAll(RegExp(r'[.,;:!?]+$'), '');
  if (words.length > maxWords) t = '$t…';
  return t[0].toUpperCase() + t.substring(1);
}

String formatDuration(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String formatClock(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

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
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String formatDate(DateTime d) =>
    '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

/// Section header for the notes list: TODAY, YESTERDAY or a date.
String dayLabel(DateTime d, DateTime now) {
  final day = DateTime(d.year, d.month, d.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'TODAY';
  if (diff == 1) return 'YESTERDAY';
  return formatDate(d).toUpperCase();
}
