import 'package:flutter_test/flutter_test.dart';
import 'package:hey_notes/util/commands.dart';

void main() {
  test('append at the start, rest kept', () {
    final c = parseCommands('Add this to my last note, also buy batteries.');
    expect(c.append, isTrue);
    expect(c.text, 'buy batteries.');
  });

  test('tag at the end, stripped from the text', () {
    final c = parseCommands(
      'The quarterly report is due on Friday and I still need the numbers from Sarah. Tag it work.',
    );
    expect(c.tags, ['work']);
    expect(
      c.text,
      'The quarterly report is due on Friday and I still need the numbers from Sarah.',
    );
  });

  test('checklist at the start', () {
    final c = parseCommands(
      'Make it a checklist. Pack the charger, passport, sunscreen and the hotel booking printout.',
    );
    expect(c.checklist, isTrue);
    expect(c.text, startsWith('Pack the charger'));
  });

  test('reminder plus tag', () {
    final c = parseCommands(
      'Remind me on Monday to pay the electricity bill. Tag it home.',
    );
    expect(c.remind, isTrue);
    expect(c.tags, ['home']);
    expect(c.text, 'Remind me on Monday to pay the electricity bill.');
  });

  test('several commands at both ends', () {
    final c = parseCommands(
      'Add this to my last note. Eggs and milk. Make it a checklist and tag it shopping.',
    );
    expect(c.append, isTrue);
    expect(c.checklist, isTrue);
    expect(c.tags, ['shopping']);
    expect(c.text, 'Eggs and milk.');
  });

  test('traps: talking about features is not a command', () {
    for (final t in [
      'I should build a feature that reminds users to drink water every two hours.',
      'Remember that the best time to plant a tree was twenty years ago.',
      'We could tag it later in the meeting and decide then.',
      'I want to add a way to make it a checklist in the app settings page.',
    ]) {
      final c = parseCommands(t);
      expect(c.any, isFalse, reason: t);
      expect(c.text, t);
    }
  });

  test('toChecklist turns bullets into tick boxes, once', () {
    expect(
      toChecklist('Pack:\n- Charger\n- Passport\n- [x] Done already'),
      'Pack:\n- [ ] Charger\n- [ ] Passport\n- [x] Done already',
    );
  });
}
