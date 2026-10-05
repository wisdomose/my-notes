import 'dart:async';

import 'package:flutter/material.dart';

import '../data/note.dart';
import '../main.dart';
import '../theme.dart';
import '../util/text.dart';
import 'note_screen.dart';
import 'widgets.dart';

/// "Saved to Notes" confirmation with Undo / Edit / Done.
Future<void> showSavedSheet(
  BuildContext context,
  Note note, {
  required VoidCallback onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: C.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => _SavedSheet(note: note, onChanged: onChanged),
  );
}

class _SavedSheet extends StatefulWidget {
  const _SavedSheet({required this.note, required this.onChanged});

  final Note note;
  final VoidCallback onChanged;

  @override
  State<_SavedSheet> createState() => _SavedSheetState();
}

class _SavedSheetState extends State<_SavedSheet> {
  Timer? _autoClose;

  @override
  void initState() {
    super.initState();
    // A failure stays up until dismissed.
    if (widget.note.failed) return;
    _autoClose = Timer(const Duration(seconds: 6), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _autoClose?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final failed = note.failed;
    final listening = services.settings.wakeEnabled;
    return Listener(
      // Any touch keeps the sheet open.
      onPointerDown: (_) => _autoClose?.cancel(),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: C.faint,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: failed ? C.danger : C.ok,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      failed ? Icons.priority_high_rounded : Ic.check,
                      size: 28,
                      color: C.bgDeep,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        failed ? 'Couldn’t transcribe' : 'Saved to Notes',
                        style: display(24),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Today ${formatClock(note.createdAt)} · ${formatDuration(note.durationMs)}',
                        style: mono(12),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: C.bg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: C.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (failed)
                      Text(
                        note.error!,
                        style: sans(15, color: C.textSoft, height: 1.5),
                      )
                    else ...[
                      Text(note.title, style: sans(16, weight: 600)),
                      const SizedBox(height: 6),
                      Text(
                        note.body,
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: sans(15, color: C.textSoft, height: 1.5),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: PillButton(
                      label: failed ? 'Delete' : 'Undo',
                      icon: failed ? Ic.delete : Ic.undo,
                      onPressed: () async {
                        await services.db.delete(note.id!);
                        widget.onChanged();
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: failed
                        ? PillButton(
                            label: 'Retry',
                            icon: Icons.refresh_rounded,
                            onPressed: () {
                              services.voice.retry(note.id!);
                              Navigator.of(context).pop();
                            },
                          )
                        : PillButton(
                            label: 'Edit',
                            icon: Ic.edit,
                            onPressed: () async {
                              final nav = Navigator.of(context);
                              nav.pop();
                              await nav.push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      NoteScreen(note: note, editing: true),
                                ),
                              );
                              widget.onChanged();
                            },
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PillButton(
                      label: 'Done',
                      filled: true,
                      fill: C.accent,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: listening ? C.ok : C.faint,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    listening
                        ? 'Listening for “Hey Notes” again'
                        : 'Wake word is off',
                    style: sans(13, color: C.muted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
