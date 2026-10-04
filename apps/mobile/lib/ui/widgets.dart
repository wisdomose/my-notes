import 'package:flutter/material.dart';

import '../theme.dart';

/// Stroke icons drawn to match the design canvas.
class Ic {
  static const mic = Icons.mic_none_rounded;
  static const search = Icons.search_rounded;
  static const settings = Icons.tune_rounded;
  static const back = Icons.arrow_back_ios_new_rounded;
  static const close = Icons.close_rounded;
  static const check = Icons.check_rounded;
  static const undo = Icons.undo_rounded;
  static const edit = Icons.edit_outlined;
  static const copy = Icons.copy_rounded;
  static const share = Icons.ios_share_rounded;
  static const delete = Icons.delete_outline_rounded;
  static const play = Icons.play_arrow_rounded;
  static const pause = Icons.pause_rounded;
  static const more = Icons.more_horiz_rounded;
  static const chevron = Icons.chevron_right_rounded;
  static const download = Icons.download_rounded;
}

class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color = C.text,
    this.size = 22,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: size, color: color),
      style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
    child: Text(text, style: mono(12, spacing: 1)),
  );
}

class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.filled = false,
    this.fill = C.text,
    this.height = 52,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool filled;
  final Color fill;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? C.bgDeep : C.text;
    return SizedBox(
      height: height,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          backgroundColor: filled ? fill : Colors.transparent,
          foregroundColor: fg,
          shape: StadiumBorder(
            side: filled ? BorderSide.none : const BorderSide(color: C.border),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: fg),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: sans(15, weight: filled ? 600 : 500, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bars for a waveform; values are 0..1.
class Waveform extends StatelessWidget {
  const Waveform({
    super.key,
    required this.levels,
    this.height = 48,
    this.barWidth = 4,
    this.gap = 4,
    this.activeCount,
    this.color = C.accent,
  });

  final List<double> levels;
  final double height;
  final double barWidth;
  final double gap;
  final int? activeCount;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < levels.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              width: barWidth,
              height: 6 + (height - 6) * levels[i].clamp(0.0, 1.0),
              decoration: BoxDecoration(
                color: activeCount == null || i < activeCount!
                    ? color
                    : C.faint,
                borderRadius: BorderRadius.circular(barWidth / 2),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

void showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
