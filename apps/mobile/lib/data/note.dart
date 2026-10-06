class Note {
  const Note({
    this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    this.durationMs = 0,
    this.audioPath,
    this.source = 'voice',
    this.error,
    this.transcript,
    this.tidyError,
    this.tags = const [],
    this.remindAt,
  });

  final int? id;
  final String title;
  final String body;
  final DateTime createdAt;
  final int durationMs;
  final String? audioPath;

  /// 'voice' or 'typed'.
  final String source;

  /// Set when the note couldn't be transcribed (its audio is kept so it
  /// can be retried). Null once it has text.
  final String? error;
  bool get failed => error != null;

  /// The words as transcribed, kept when the note was tidied up (title,
  /// cleanup, lists) so the original is one tap away.
  final String? transcript;

  /// Set when tidying failed: the note shows the raw transcript and can be
  /// retried.
  final String? tidyError;

  /// Lower-case tags ("tag it work").
  final List<String> tags;

  /// When the note's reminder fires ("remind me tomorrow at 9 …").
  final DateTime? remindAt;

  Note copyWith({
    String? title,
    String? body,
    String? audioPath,
    String? Function()? error,
    String? Function()? transcript,
    String? Function()? tidyError,
    List<String>? tags,
    DateTime? Function()? remindAt,
  }) => Note(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    createdAt: createdAt,
    durationMs: durationMs,
    audioPath: audioPath ?? this.audioPath,
    source: source,
    error: error == null ? this.error : error(),
    transcript: transcript == null ? this.transcript : transcript(),
    tidyError: tidyError == null ? this.tidyError : tidyError(),
    tags: tags ?? this.tags,
    remindAt: remindAt == null ? this.remindAt : remindAt(),
  );

  /// The same note with its recording reference dropped.
  Note withoutAudio() => Note(
    id: id,
    title: title,
    body: body,
    createdAt: createdAt,
    durationMs: durationMs,
    source: source,
    error: error,
    transcript: transcript,
    tidyError: tidyError,
    tags: tags,
    remindAt: remindAt,
  );

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'title': title,
    'body': body,
    'created_at': createdAt.millisecondsSinceEpoch,
    'duration_ms': durationMs,
    'audio_path': audioPath,
    'source': source,
    'error': error,
    'transcript': transcript,
    'tidy_error': tidyError,
    'tags': tags.join(','),
    'remind_at': remindAt?.millisecondsSinceEpoch,
  };

  factory Note.fromMap(Map<String, Object?> m) => Note(
    id: m['id'] as int,
    title: m['title'] as String,
    body: m['body'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
    durationMs: m['duration_ms'] as int? ?? 0,
    audioPath: m['audio_path'] as String?,
    source: m['source'] as String? ?? 'voice',
    error: m['error'] as String?,
    transcript: m['transcript'] as String?,
    tidyError: m['tidy_error'] as String?,
    tags: ((m['tags'] as String?) ?? '')
        .split(',')
        .where((t) => t.isNotEmpty)
        .toList(),
    remindAt: switch (m['remind_at']) {
      final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      _ => null,
    },
  );
}
