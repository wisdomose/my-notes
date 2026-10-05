import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Diagnostics log on disk, so it survives the app being killed. Written
/// by both the UI and the voice service (one line per write, appended).
class LogFile {
  static File? _file;
  static const _maxBytes = 256 * 1024;

  static Future<File> _get() async => _file ??= File(
    '${(await getApplicationSupportDirectory()).path}/diagnostics.log',
  );

  static Future<void> append(String line) async {
    try {
      final f = await _get();
      final t = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp =
          '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
      await f.writeAsString(
        '$stamp $line\n',
        mode: FileMode.append,
        flush: true,
      );
      if (await f.length() > _maxBytes) {
        // Keep the newest half.
        final text = await f.readAsString();
        await f.writeAsString(text.substring(text.length ~/ 2));
      }
    } catch (_) {
      // Logging must never break the app.
    }
  }

  /// The newest [max] lines, oldest first.
  static Future<List<String>> read({int max = 400}) async {
    try {
      final f = await _get();
      if (!await f.exists()) return [];
      final lines = (await f.readAsLines()).where((l) => l.isNotEmpty).toList();
      return lines.length > max ? lines.sublist(lines.length - max) : lines;
    } catch (_) {
      return [];
    }
  }

  static Future<void> clear() async {
    try {
      await (await _get()).writeAsString('');
    } catch (_) {}
  }
}
