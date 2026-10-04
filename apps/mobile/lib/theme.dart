import 'package:flutter/material.dart';

/// Palette from the Hey Notes design canvas.
class C {
  static const bg = Color(0xFF101312);
  static const bgDeep = Color(0xFF0B0D0C);
  static const surface = Color(0xFF1A1F1D);
  static const card = Color(0xFF171B19);
  static const border = Color(0xFF2A302D);
  static const text = Color(0xFFECEFEA);
  static const textSoft = Color(0xFFB8BFBA);
  static const muted = Color(0xFF9BA39E);
  static const faint = Color(0xFF3A403C);
  static const accent = Color(0xFFF5B841);
  static const accentDim = Color(0xFF2B2615);
  static const ok = Color(0xFF6FD08C);
  static const rec = Color(0xFFFF6B5B);
  static const danger = Color(0xFFFF8A7A);
}

TextStyle display(double size, {Color color = C.text}) => TextStyle(
  fontFamily: 'Bricolage',
  fontSize: size,
  fontWeight: FontWeight.w700,
  fontVariations: const [FontVariation('wght', 700)],
  letterSpacing: -0.3,
  height: 1.15,
  color: color,
);

TextStyle sans(
  double size, {
  double weight = 400,
  Color color = C.text,
  double? height,
}) => TextStyle(
  fontFamily: 'PlexSans',
  fontSize: size,
  fontWeight: FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)],
  fontVariations: [FontVariation('wght', weight)],
  color: color,
  height: height,
);

TextStyle mono(double size, {Color color = C.muted, double spacing = 0}) =>
    TextStyle(
      fontFamily: 'PlexMono',
      fontSize: size,
      color: color,
      letterSpacing: spacing,
    );

ThemeData buildTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: C.bg,
    fontFamily: 'PlexSans',
    colorScheme: const ColorScheme.dark(
      primary: C.accent,
      onPrimary: C.bg,
      secondary: C.accent,
      surface: C.surface,
      onSurface: C.text,
      error: C.danger,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: C.surface,
      contentTextStyle: sans(14),
      behavior: SnackBarBehavior.floating,
      actionTextColor: C.accent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: C.surface,
      titleTextStyle: display(22),
      contentTextStyle: sans(15, color: C.textSoft, height: 1.45),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? C.bg : C.text,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? C.accent : C.faint,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: C.accent,
      inactiveTrackColor: C.faint,
      thumbColor: C.accent,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: C.accent,
      selectionColor: Color(0x55F5B841),
      selectionHandleColor: C.accent,
    ),
  );
}
