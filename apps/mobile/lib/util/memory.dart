import 'dart:io';

/// Phone memory from /proc/meminfo (readable by apps on Android and Linux).
class DeviceMemory {
  const DeviceMemory({required this.total, required this.available});

  final int total;
  final int available;

  static Future<DeviceMemory?> read() async {
    try {
      final info = await File('/proc/meminfo').readAsString();
      int? kb(String key) {
        final m = RegExp(
          '^$key:\\s+(\\d+) kB',
          multiLine: true,
        ).firstMatch(info);
        return m == null ? null : int.parse(m.group(1)!) * 1024;
      }

      final total = kb('MemTotal');
      final available = kb('MemAvailable');
      if (total == null || available == null) return null;
      return DeviceMemory(total: total, available: available);
    } catch (_) {
      return null;
    }
  }
}
