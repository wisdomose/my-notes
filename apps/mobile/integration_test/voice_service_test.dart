// End-to-end on a real Android device/emulator: the app starts the
// foreground voice service, the service loads the models and opens the
// microphone, a manual capture starts, and (with nobody talking) it ends on
// the no-speech timeout. Run with scripts/e2e.sh, which pre-grants the mic.
import 'package:flutter_test/flutter_test.dart';
import 'package:hey_notes/main.dart' as app;
import 'package:hey_overlay/hey_overlay.dart';
import 'package:hey_notes/voice/voice_engine.dart';
import 'package:integration_test/integration_test.dart';

Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done,
  Duration timeout,
  String what,
) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) {
      fail(
        'Timed out waiting for $what.\n--- app log ---\n'
        '${app.services.voice.log.join('\n')}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('voice service starts, hears the mic and captures', (
    tester,
  ) async {
    await app.main();
    await tester.pump();
    final voice = app.services.voice;

    await pumpUntil(
      tester,
      () => voice.engineReady || voice.statusError,
      const Duration(minutes: 3),
      'the voice engine to load',
    );
    expect(voice.statusError, isFalse, reason: voice.log.join('\n'));

    await pumpUntil(
      tester,
      () => voice.log.any((l) => l.contains('first audio chunk')),
      const Duration(seconds: 30),
      'audio from the microphone (wake-word listening)',
    );

    expect(await voice.startCapture(), isTrue);
    await pumpUntil(
      tester,
      () => voice.state == EngineState.capturing,
      const Duration(seconds: 20),
      'the capture to start',
    );

    // Nobody is talking, so it should give up after the no-speech timeout.
    await pumpUntil(
      tester,
      () => voice.state == EngineState.idle,
      const Duration(seconds: 30),
      'the capture to end',
    );

    // ignore: avoid_print
    print('--- app log ---\n${voice.log.join('\n')}');
  });

  // scripts/e2e.sh grants "Display over other apps" with appops.
  testWidgets('overlay shows every state over other apps and hides', (
    tester,
  ) async {
    expect(await HeyOverlay.canDraw(), isTrue);
    for (final state in OverlayState.values) {
      await HeyOverlay.show(state, text: 'Buy bread and eggs', level: 0.6);
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    await HeyOverlay.hide();
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });
}
