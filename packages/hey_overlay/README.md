# hey_overlay

Hey Notes' "listening over other apps" overlay (Android only): the screen
edges glow and a status bubble sits near the bottom.

```dart
if (await HeyOverlay.canDraw()) {
  await HeyOverlay.show(OverlayState.listening, text: partial, level: 0.4);
  await HeyOverlay.show(OverlayState.transcribing);
  await HeyOverlay.show(OverlayState.saved, text: note.title);
  await HeyOverlay.hide();
} else {
  await HeyOverlay.openPermissionSettings(); // "Display over other apps"
}
```

- One `TYPE_APPLICATION_OVERLAY` window, created from whichever engine calls
  it (the app uses the background voice service). No service or Flutter
  engine of its own, so Android 14/15 background-start limits don't apply.
- Touches pass through (`FLAG_NOT_TOUCHABLE`, window alpha 0.8, which
  Android 12+ requires for pass-through).
- Removed automatically after 3 minutes without updates.
