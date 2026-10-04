class Note {
  const Note({
    this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    this.durationMs = 0,
    this.audioPath,
    this.source = 'voice',
  });

  final int? id;
  final String title;
  final String body;
  final DateTime createdAt;
  final int durationMs;
  final String? audioPath;

  /// 'voice' or 'typed'.
  final String source;

  Note copyWith({String? title, String? body, String? audioPath}) => Note(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    createdAt: createdAt,
    durationMs: durationMs,
    audioPath: audioPath ?? this.audioPath,
    source: source,
  );

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'title': title,
    'body': body,
    'created_at': createdAt.millisecondsSinceEpoch,
    'duration_ms': durationMs,
    'audio_path': audioPath,
    'source': source,
  };

  factory Note.fromMap(Map<String, Object?> m) => Note(
    id: m['id'] as int,
    title: m['title'] as String,
    body: m['body'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
    durationMs: m['duration_ms'] as int? ?? 0,
    audioPath: m['audio_path'] as String?,
    source: m['source'] as String? ?? 'voice',
  );
}
