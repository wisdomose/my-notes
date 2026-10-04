import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../data/note.dart';
import '../main.dart';
import '../theme.dart';
import '../util/text.dart';
import 'widgets.dart';

class NoteScreen extends StatefulWidget {
  const NoteScreen({super.key, required this.note, this.editing = false});

  final Note note;
  final bool editing;

  @override
  State<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends State<NoteScreen> {
  late Note _note = widget.note;
  late bool _editing = widget.editing;
  late final _title = TextEditingController(text: _note.title);
  late final _body = TextEditingController(text: _note.body);
  final _player = AudioPlayer();
  bool _playing = false;
  double _progress = 0;
  final List<StreamSubscription<dynamic>> _subs = [];

  bool get _hasAudio =>
      _note.audioPath != null && File(_note.audioPath!).existsSync();

  @override
  void initState() {
    super.initState();
    _subs
      ..add(
        _player.onPlayerStateChanged.listen((s) {
          if (mounted) setState(() => _playing = s == PlayerState.playing);
        }),
      )
      ..add(
        _player.onPositionChanged.listen((p) {
          if (mounted && _note.durationMs > 0) {
            setState(
              () => _progress = (p.inMilliseconds / _note.durationMs).clamp(
                0.0,
                1.0,
              ),
            );
          }
        }),
      )
      ..add(
        _player.onPlayerComplete.listen((_) {
          if (mounted) setState(() => _progress = 0);
        }),
      );
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final body = _body.text.trim();
    final title = _title.text.trim().isEmpty
        ? makeTitle(body)
        : _title.text.trim();
    final updated = _note.copyWith(title: title, body: body);
    await services.db.update(updated);
    setState(() {
      _note = updated;
      _editing = false;
    });
    if (mounted) FocusScope.of(context).unfocus();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this note?'),
        content: const Text('This can’t be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Keep', style: sans(15, weight: 500)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Delete',
              style: sans(15, weight: 600, color: C.danger),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await services.db.delete(_note.id!);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
    } else if (_player.state == PlayerState.paused) {
      await _player.resume();
    } else {
      await _player.play(DeviceFileSource(_note.audioPath!));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editing) _save();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: Row(
                  children: [
                    RoundIconButton(
                      icon: Ic.back,
                      tooltip: 'Back',
                      size: 20,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    if (_editing)
                      TextButton(
                        onPressed: _save,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(64, 44),
                        ),
                        child: Text(
                          'Save',
                          style: sans(16, weight: 600, color: C.accent),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  children: [
                    if (_editing)
                      TextField(
                        controller: _title,
                        style: display(30),
                        maxLines: null,
                        decoration: InputDecoration(
                          hintText: 'Title',
                          hintStyle: display(30, color: C.faint),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      )
                    else
                      Text(_note.title, style: display(30)),
                    const SizedBox(height: 10),
                    Text(
                      [
                        '${formatDate(_note.createdAt)} · ${formatClock(_note.createdAt)}',
                        if (_note.source == 'voice')
                          'Voice note · ${formatDuration(_note.durationMs)}',
                      ].join(' · '),
                      style: mono(12),
                    ),
                    if (_hasAudio) ...[const SizedBox(height: 20), _audioBar()],
                    const SizedBox(height: 24),
                    if (_editing)
                      TextField(
                        controller: _body,
                        autofocus: widget.editing,
                        maxLines: null,
                        style: sans(18, height: 1.6),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      )
                    else
                      SelectableText(_note.body, style: sans(18, height: 1.6)),
                  ],
                ),
              ),
              if (!_editing) _actions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _audioBar() {
    final bars = List.generate(34, (i) {
      final seed = (_note.id ?? 1) * 31 + i * 17;
      return 0.2 + 0.8 * ((math.sin(seed.toDouble()) + 1) / 2);
    });
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Material(
            color: C.accent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _togglePlay,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  _playing ? Ic.pause : Ic.play,
                  color: C.bg,
                  semanticLabel: _playing ? 'Pause' : 'Play recording',
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRect(
              child: Waveform(
                levels: bars,
                height: 32,
                barWidth: 3,
                gap: 3,
                activeCount: (_progress * bars.length).round(),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(formatDuration(_note.durationMs), style: mono(12)),
        ],
      ),
    );
  }

  Widget _actions() {
    Widget action(
      IconData icon,
      String label,
      VoidCallback onTap, {
      Color color = C.text,
    }) {
      return Expanded(
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 56),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            foregroundColor: color,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(height: 4),
              Text(label, style: sans(12, color: color)),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          action(Ic.edit, 'Edit', () => setState(() => _editing = true)),
          action(Ic.copy, 'Copy', () async {
            await Clipboard.setData(ClipboardData(text: _note.body));
            if (mounted) showError(context, 'Copied');
          }),
          action(Ic.share, 'Share', () {
            SharePlus.instance.share(
              ShareParams(text: _note.body, subject: _note.title),
            );
          }),
          action(Ic.delete, 'Delete', _delete, color: C.danger),
        ],
      ),
    );
  }
}
