/// The over-other-apps listening overlay: glowing screen edges and a status
/// bubble at the bottom. Android only; touches pass straight through it.
///
/// Works from any Flutter engine in the app process, including the
/// background voice service, since the window lives in a native singleton.
library;

import 'package:flutter/services.dart';

enum OverlayState {
  /// "Listening…", with live text and a level-driven pulse.
  listening,

  /// "Transcribing…" with a spinner.
  transcribing,

  /// "Saved", with the note title; the caller hides it shortly after.
  saved,

  /// "Didn't catch that".
  nothing,
}

class HeyOverlay {
  static const _channel = MethodChannel('hey_overlay');

  /// Whether "Display over other apps" is allowed.
  static Future<bool> canDraw() async =>
      await _channel.invokeMethod<bool>('canDraw') ?? false;

  /// Opens the system "Display over other apps" screen for this app.
  static Future<void> openPermissionSettings() =>
      _channel.invokeMethod<void>('openPermissionSettings');

  /// Shows the overlay, or updates it if it's already visible. [text] is
  /// the live transcript or note title; [level] (0..1) drives the pulse.
  static Future<void> show(
    OverlayState state, {
    String text = '',
    double level = 0,
  }) => _channel.invokeMethod<void>('show', {
    'state': state.name,
    'text': text,
    'level': level,
  });

  /// Whether the overlay window is currently on screen.
  static Future<bool> isShowing() async =>
      await _channel.invokeMethod<bool>('isShowing') ?? false;

  /// Fades the overlay out and removes it.
  static Future<void> hide() => _channel.invokeMethod<void>('hide');
}
