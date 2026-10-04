import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hey_overlay/hey_overlay.dart';

import '../data/note.dart';
import '../main.dart';
import '../theme.dart';
import '../util/text.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_engine.dart';
import '../voice/whisper_download.dart';
import 'listening_screen.dart';
import 'note_screen.dart';
import 'saved_sheet.dart';
import 'settings_screen.dart';
import 'widgets.dart';

enum _Filter { all, today, week }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _voice = services.voice;
  final _search = TextEditingController();
  List<Note> _notes = [];
  bool _loaded = false;
  bool _searching = false;
  _Filter _filter = _Filter.all;
  bool _listeningOpen = false;

  /// "Display over other apps" is allowed (null until checked).
  bool? _canDrawOverlay;

  /// The app is on screen. "Hey Notes" said elsewhere must not open the
  /// Listening screen behind the user's back (the overlay covers that).
  bool _foreground =
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused &&
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.hidden;

  /// A note saved while the app was in the background, shown on return.
  SavedEvent? _savedWhileAway;
  DateTime? _savedWhileAwayAt;
  late final StreamSubscription<SavedEvent> _savedSub;
  late final StreamSubscription<void> _nothingSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _voice.addListener(_onVoice);
    _savedSub = _voice.saved.listen(_onSaved);
    _nothingSub = _voice.nothingHeard.listen((_) {
      if (mounted) showError(context, 'Didn’t catch anything. Try again.');
    });
    _load();
    _checkOverlay();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _voice.startListeningIfEnabled();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voice.removeListener(_onVoice);
    _savedSub.cancel();
    _nothingSub.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _load();
      _checkOverlay();
      _voice.refresh();
      _voice.startListeningIfEnabled();
      // Still recording when they come back: show it.
      if (_voice.state != EngineState.idle && !_listeningOpen) {
        _openListening();
      }
      _showSavedWhileAway();
    }
  }

  /// "This is what you recorded": the sheet for a note saved while away,
  /// on the Home screen, if it was saved in the last 10 minutes.
  void _showSavedWhileAway() {
    final e = _savedWhileAway;
    final at = _savedWhileAwayAt;
    _savedWhileAway = null;
    _savedWhileAwayAt = null;
    if (e == null || at == null) return;
    if (DateTime.now().difference(at) > const Duration(minutes: 10)) return;
    _onSaved(e);
  }

  Future<void> _checkOverlay() async {
    final ok = await HeyOverlay.canDraw();
    if (mounted) setState(() => _canDrawOverlay = ok);
  }

  Future<void> _load() async {
    final notes = await services.db.list(query: _search.text);
    if (mounted) {
      setState(() {
        _notes = notes;
        _loaded = true;
      });
    }
  }

  void _onVoice() {
    final err = _voice.error;
    if (err != null && mounted) {
      showError(context, err);
      _voice.clearError();
    }
    if (_voice.state == EngineState.capturing &&
        !_listeningOpen &&
        _foreground) {
      _openListening();
    }
    if (mounted) setState(() {});
  }

  Future<void> _openListening() async {
    _listeningOpen = true;
    await Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, _, _) => const ListeningScreen(),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
    _listeningOpen = false;
  }

  Future<void> _onSaved(SavedEvent e) async {
    if (!_foreground) {
      // Show it when they open the app, not now (its timer would run out).
      _savedWhileAway = e;
      _savedWhileAwayAt = DateTime.now();
      _load();
      return;
    }
    await _load();
    final note = await services.db.get(e.noteId);
    if (note == null || !mounted) return;
    // Let the listening screen close first.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    showSavedSheet(context, note, onChanged: _load);
  }

  Future<void> _mic() async {
    final ok = await _voice.startCapture();
    if (ok && !_listeningOpen && mounted) _openListening();
  }

  List<Note> get _visible {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (_filter) {
      _Filter.all => _notes,
      _Filter.today =>
        _notes.where((n) => !n.createdAt.isBefore(today)).toList(),
      _Filter.week =>
        _notes
            .where(
              (n) => !n.createdAt.isBefore(
                today.subtract(Duration(days: today.weekday - 1)),
              ),
            )
            .toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _header()),
                SliverToBoxAdapter(child: _statusCard()),
                SliverToBoxAdapter(child: _overlayBanner()),
                SliverToBoxAdapter(child: _whisperBanner()),
                SliverToBoxAdapter(child: _chips()),
                if (_loaded && visible.isEmpty)
                  SliverFillRemaining(hasScrollBody: false, child: _empty())
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 180),
                    sliver: SliverList.list(children: _noteTiles(visible)),
                  ),
              ],
            ),
            Positioned(left: 0, right: 0, bottom: 0, child: _micDock()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
      child: _searching
          ? Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    autofocus: true,
                    style: sans(18),
                    onChanged: (_) => _load(),
                    decoration: InputDecoration(
                      hintText: 'Search notes',
                      hintStyle: sans(18, color: C.muted),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                RoundIconButton(
                  icon: Ic.close,
                  tooltip: 'Close search',
                  onPressed: () {
                    _search.clear();
                    setState(() => _searching = false);
                    _load();
                  },
                ),
              ],
            )
          : Row(
              children: [
                Expanded(child: Text('Notes', style: display(34))),
                RoundIconButton(
                  icon: Ic.search,
                  tooltip: 'Search notes',
                  onPressed: () => setState(() => _searching = true),
                ),
                RoundIconButton(
                  icon: Ic.settings,
                  tooltip: 'Settings',
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsScreen(),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
    );
  }

  Widget _statusCard() {
    final on = services.settings.wakeEnabled;
    final live = on && _voice.serviceRunning;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.border),
      ),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: C.accentDim,
                  shape: BoxShape.circle,
                ),
                child: Icon(Ic.mic, color: on ? C.accent : C.muted, size: 22),
              ),
              if (live)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: C.ok,
                      shape: BoxShape.circle,
                      border: Border.all(color: C.surface, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  on ? 'Listening for “Hey Notes”' : 'Wake word is off',
                  style: sans(15, weight: 600),
                ),
                const SizedBox(height: 2),
                Text(
                  on
                      ? (live
                            ? 'Works with the screen off · on-device'
                            : 'Starting…')
                      : 'Tap the mic below to record',
                  style: sans(13, color: C.muted),
                ),
              ],
            ),
          ),
          Switch(value: on, onChanged: (v) => _voice.setWakeEnabled(v)),
        ],
      ),
    );
  }

  /// Asks for "Display over other apps" so "Hey Notes" can show its bubble
  /// and glowing edges while you're in another app.
  Widget _overlayBanner() {
    final settings = services.settings;
    if (_canDrawOverlay != false ||
        !settings.wakeEnabled ||
        !settings.overlayEnabled) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('See it listening in any app', style: sans(14, weight: 600)),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              'Allow “Display over other apps” and the screen edges glow with '
              'a bubble at the bottom when you say “Hey Notes”.',
              style: sans(13, color: C.muted, height: 1.4),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () async {
                  settings.overlayEnabled = false;
                  await settings.save();
                  setState(() {});
                },
                style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                child: Text('Not now', style: sans(14, color: C.muted)),
              ),
              TextButton(
                onPressed: HeyOverlay.openPermissionSettings,
                style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                child: Text(
                  'Allow',
                  style: sans(15, weight: 600, color: C.accent),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _whisperBanner() {
    final whisper = services.whisper;
    return ListenableBuilder(
      listenable: whisper,
      builder: (context, _) {
        if (whisper.status == WhisperStatus.ready) {
          return const SizedBox.shrink();
        }
        final downloading = whisper.status == WhisperStatus.downloading;
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      downloading
                          ? 'Downloading accurate model… ${(whisper.progress * 100).round()}%'
                          : 'Better accuracy for your accent',
                      style: sans(14, weight: 600),
                    ),
                    const SizedBox(height: 4),
                    if (downloading)
                      LinearProgressIndicator(
                        value: whisper.progress,
                        color: C.accent,
                        backgroundColor: C.faint,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(2),
                      )
                    else
                      Text(
                        whisper.error ??
                            'One-time ${WhisperDownload.sizeLabel} download. Runs offline after.',
                        style: sans(13, color: C.muted),
                      ),
                  ],
                ),
              ),
              if (!downloading)
                TextButton(
                  onPressed: whisper.start,
                  style: TextButton.styleFrom(
                    foregroundColor: C.accent,
                    minimumSize: const Size(44, 44),
                  ),
                  child: Text(
                    whisper.status == WhisperStatus.failed ? 'Retry' : 'Get',
                    style: sans(15, weight: 600, color: C.accent),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _chips() {
    final today = _notes
        .where((n) => dayLabel(n.createdAt, DateTime.now()) == 'TODAY')
        .length;
    Widget chip(_Filter f, String label) {
      final sel = _filter == f;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: SizedBox(
          height: 36,
          child: TextButton(
            onPressed: () => setState(() => _filter = f),
            style: TextButton.styleFrom(
              backgroundColor: sel ? C.text : Colors.transparent,
              foregroundColor: sel ? C.bg : C.text,
              shape: StadiumBorder(
                side: sel ? BorderSide.none : const BorderSide(color: C.border),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            child: Text(
              label,
              style: sans(
                14,
                weight: sel ? 500 : 400,
                color: sel ? C.bg : C.text,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            chip(_Filter.all, 'All · ${_notes.length}'),
            chip(_Filter.today, today > 0 ? 'Today · $today' : 'Today'),
            chip(_Filter.week, 'This week'),
          ],
        ),
      ),
    );
  }

  List<Widget> _noteTiles(List<Note> notes) {
    final now = DateTime.now();
    final out = <Widget>[];
    String? last;
    for (final n in notes) {
      final label = dayLabel(n.createdAt, now);
      if (label != last) {
        out.add(SectionLabel(label));
        out.add(const SizedBox(height: 10));
        last = label;
      }
      out.add(_NoteCard(note: n, onTap: () => _open(n)));
      out.add(const SizedBox(height: 10));
    }
    return out;
  }

  Future<void> _open(Note n) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => NoteScreen(note: n)));
    _load();
  }

  Widget _empty() {
    final searching = _search.text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 180),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            searching ? 'No matches' : 'No notes yet',
            style: display(24),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            searching ? 'Try a different word.' : 'Say “Hey Notes”, then speak. Your note saves when you stop talking.',
            style: sans(15, color: C.muted, height: 1.45),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _micDock() {
    return IgnorePointer(
      ignoring: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          0,
          40,
          0,
          20 + MediaQuery.of(context).padding.bottom,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00101312), C.bg],
            stops: [0, 0.45],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              label: 'Start a voice note',
              child: Material(
                color: C.accent,
                shape: const CircleBorder(),
                elevation: 6,
                shadowColor: const Color(0x66F5B841),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _mic,
                  child: const SizedBox(
                    width: 76,
                    height: 76,
                    child: Icon(Ic.mic, size: 34, color: C.bg),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Tap, or just say ',
                    style: sans(13, color: C.muted),
                  ),
                  TextSpan(text: '“Hey Notes”', style: sans(13, weight: 500)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note, required this.onTap});

  final Note note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: C.card,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(16, weight: 600),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(formatClock(note.createdAt), style: mono(12)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                note.body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: sans(14, color: C.textSoft, height: 1.45),
              ),
              if (note.source == 'voice') ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Ic.mic, size: 14, color: C.muted),
                    const SizedBox(width: 6),
                    Text(
                      'Voice · ${formatDuration(note.durationMs)}',
                      style: mono(12),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
