import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'note.dart';

/// Local SQLite store. Opened by both the UI and the background voice service.
class NotesDb {
  NotesDb._(this._db);

  final Database _db;

  static Future<NotesDb> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'notes.db'),
      version: 2,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE notes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          duration_ms INTEGER NOT NULL DEFAULT 0,
          audio_path TEXT,
          source TEXT NOT NULL DEFAULT 'voice',
          error TEXT
        )
      '''),
      onUpgrade: (db, from, _) async {
        // v2: notes that couldn't be transcribed.
        if (from < 2) {
          await db.execute('ALTER TABLE notes ADD COLUMN error TEXT');
        }
      },
    );
    return NotesDb._(db);
  }

  Future<int> insert(Note note) => _db.insert('notes', note.toMap());

  Future<void> update(Note note) =>
      _db.update('notes', note.toMap(), where: 'id = ?', whereArgs: [note.id]);

  Future<Note?> get(int id) async {
    final rows = await _db.query('notes', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Note.fromMap(rows.first);
  }

  Future<void> delete(int id) async {
    final note = await get(id);
    await _db.delete('notes', where: 'id = ?', whereArgs: [id]);
    final audio = note?.audioPath;
    if (audio != null) {
      final f = File(audio);
      if (await f.exists()) await f.delete();
    }
  }

  Future<List<Note>> list({String query = ''}) async {
    final q = query.trim();
    final rows = await _db.query(
      'notes',
      where: q.isEmpty ? null : 'title LIKE ? OR body LIKE ?',
      whereArgs: q.isEmpty ? null : ['%$q%', '%$q%'],
      orderBy: 'created_at DESC',
    );
    return rows.map(Note.fromMap).toList();
  }
}
