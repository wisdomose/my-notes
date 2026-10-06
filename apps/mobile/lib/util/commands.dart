/// Voice commands spoken at the start or end of a note, matched in code
/// (more reliable than asking a model): "add this to my last note",
/// "tag it work", "make it a checklist". "Remind me …" is detected here
/// too; working out *when* is left to the API.
library;

class NoteCommands {
  const NoteCommands({
    required this.text,
    this.append = false,
    this.tags = const [],
    this.checklist = false,
    this.remind = false,
  });

  /// The note with the command phrases removed.
  final String text;

  /// Add to the previous note instead of creating a new one.
  final bool append;
  final List<String> tags;
  final bool checklist;

  /// The note asks for a reminder ("remind me …").
  final bool remind;

  bool get any => append || tags.isNotEmpty || checklist || remind;
}

// Each pattern is tried at the start and at the end of the note.
final _append = RegExp(
  r"\b(?:please\s+)?(?:add|append|put)\s+(?:this|that|it)\s+(?:to|onto|into)\s+(?:my|the)\s+(?:last|previous)\s+note\b",
  caseSensitive: false,
);
final _checklist = RegExp(
  r"\b(?:please\s+)?(?:make|turn)\s+(?:it|this|that)\s+(?:into\s+)?a\s+(?:check\s?list|to-?do\s+list)\b",
  caseSensitive: false,
);
final _tag = RegExp(
  r"\b(?:please\s+)?tag\s+(?:it|this|that)(?:\s+as)?\s+([a-z0-9][a-z0-9 \-]{0,30}?)(?=[.,!?;]|$)",
  caseSensitive: false,
);
final _remind = RegExp(
  r"^\s*(?:please\s+)?remind\s+me\b",
  caseSensitive: false,
);

NoteCommands parseCommands(String raw) {
  var text = raw.trim();
  var append = false, checklist = false;
  final tags = <String>[];

  // Peel commands off the start and the end until none are left.
  var changed = true;
  while (changed && text.isNotEmpty) {
    changed = false;
    for (final edge in [_Edge.start, _Edge.end]) {
      final a = _cut(text, _append, edge);
      if (a != null) {
        text = a.rest;
        append = changed = true;
        continue;
      }
      final c = _cut(text, _checklist, edge);
      if (c != null) {
        text = c.rest;
        checklist = changed = true;
        continue;
      }
      final t = _cut(text, _tag, edge);
      if (t != null) {
        text = t.rest;
        final name = t.match.group(1)!.trim().toLowerCase();
        if (name.isNotEmpty && !tags.contains(name)) tags.add(name);
        changed = true;
      }
    }
  }
  return NoteCommands(
    text: text,
    append: append,
    tags: tags,
    checklist: checklist,
    remind: _remind.hasMatch(text),
  );
}

enum _Edge { start, end }

/// Removes [re] when it's the first or last sentence-ish part of [text].
({String rest, RegExpMatch match})? _cut(String text, RegExp re, _Edge edge) {
  for (final m in re.allMatches(text)) {
    final before = text.substring(0, m.start);
    final after = text.substring(m.end);
    final atStart = edge == _Edge.start && _onlyFiller(before);
    final atEnd = edge == _Edge.end && _onlyFiller(after);
    if (!atStart && !atEnd) continue;
    final rest = atStart ? after : before;
    return (rest: _tidyEdges(rest), match: m);
  }
  return null;
}

final _filler = RegExp(
  r"^[\s.,;:!?\-–—]*(?:(?:and|also|oh|ok|okay|so)[\s.,;:!?\-–—]*)?$",
  caseSensitive: false,
);
bool _onlyFiller(String s) => _filler.hasMatch(s);

/// Trims separators and connecting words left at the edges after a cut.
String _tidyEdges(String s) {
  var t = s.trim();
  t = t.replaceFirst(RegExp(r"^(?:[.,;:!?\-–—]\s*)+"), '');
  t = t.replaceFirst(
    RegExp(r"^(?:and|also|so)\b[\s,]*", caseSensitive: false),
    '',
  );
  t = t.replaceFirst(
    RegExp(
      r"(?:[\s,;:\-–—]*\b(?:and|also)\b)?[\s,;:\-–—]*$",
      caseSensitive: false,
    ),
    '',
  );
  return t.trim();
}

/// "- item" lines → "- [ ] item" (a checklist the note screen can tick).
String toChecklist(String text) => text
    .split('\n')
    .map((line) {
      final m = RegExp(r'^(\s*)[-*•]\s+(?!\[[ xX]\])(.*)$').firstMatch(line);
      return m == null ? line : '${m.group(1)}- [ ] ${m.group(2)}';
    })
    .join('\n');
