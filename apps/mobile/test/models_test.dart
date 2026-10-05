import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hey_notes/data/settings.dart';
import 'package:hey_notes/util/memory.dart';
import 'package:hey_notes/voice/model_files.dart';

void main() {
  test('phones are offered only the models they can run', () {
    const phone4gb = 3800 * mb; // what a "4 GB" phone reports
    const phone6gb = 5600 * mb;
    const phone8gb = 7600 * mb;
    const phone12gb = 11400 * mb;
    expect(OfflineModel.whisper.supportsDevice(phone4gb), isTrue);
    expect(OfflineModel.parakeet.supportsDevice(phone4gb), isFalse);
    expect(OfflineModel.parakeet.supportsDevice(phone6gb), isTrue);
    expect(OfflineModel.whisperTurbo.supportsDevice(phone6gb), isFalse);
    expect(OfflineModel.whisperTurbo.supportsDevice(phone8gb), isTrue);
    expect(OfflineModel.whisperLarge.supportsDevice(phone8gb), isFalse);
    expect(OfflineModel.whisperLarge.supportsDevice(phone12gb), isTrue);
  });

  test('engine setting ↔ model', () {
    expect(AppSettings.modelFor(AppSettings.engineCloud), isNull);
    // Whisper keeps the original 'device' value for existing installs.
    expect(AppSettings.engineFor(OfflineModel.whisper), 'device');
    for (final m in OfflineModel.values) {
      expect(AppSettings.modelFor(AppSettings.engineFor(m)), m);
    }
  });

  test('model sizes', () {
    expect(OfflineModel.whisper.sizeLabel, '161 MB');
    expect(OfflineModel.parakeet.sizeLabel, '661 MB');
    expect(OfflineModel.whisperTurbo.sizeLabel, '1.0 GB');
    expect(OfflineModel.whisperLarge.sizeLabel, '1.8 GB');
  });

  test('reads memory from /proc/meminfo', () async {
    final mem = await DeviceMemory.read();
    if (!Platform.isLinux && !Platform.isAndroid) return;
    expect(mem, isNotNull);
    expect(mem!.total, greaterThan(mem.available));
    expect(mem.available, greaterThan(0));
  });
}
