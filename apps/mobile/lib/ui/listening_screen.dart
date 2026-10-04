import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../theme.dart';
import '../util/text.dart';
import '../voice/voice_engine.dart';
import 'widgets.dart';

/// Shown while a note is being captured (after "Hey Notes" or the mic button).
class ListeningScreen extends StatefulWidget {
  const ListeningScreen({super.key});

  @override
  State<ListeningScreen> createState() => _ListeningScreenState();
}

class _ListeningScreenState extends State<ListeningScreen>
    with SingleTickerProviderStateMixin {
  final _voice = services.voice;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();
  late final Timer _ticker;
  Timer? _startTimeout;
  bool _seenActive = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _voice.addListener(_onVoice);
    _ticker = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => setState(() {}),
    );
    _onVoice();
    // If the service never starts capturing, don't strand the user here.
    // Loading Whisper can take a while on first start; after that, if the
    // service still hasn't started capturing, say so instead of hanging.
    _startTimeout = Timer(const Duration(seconds: 30), () {
      if (_seenActive || !mounted) return;
      showError(
        context,
        'The voice engine didn’t respond. See Settings → Diagnostics.',
      );
      _close();
    });
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoice);
    _ticker.cancel();
    _startTimeout?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  void _onVoice() {
    if (_voice.state != EngineState.idle) _seenActive = true;
    if (_seenActive && _voice.state == EngineState.idle) _close();
    if (mounted) setState(() {});
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final transcribing = _voice.state == EngineState.transcribing;
    final started = _voice.captureStartedAt;
    final elapsed = started == null || !_seenActive
        ? Duration.zero
        : DateTime.now().difference(started);
    final level = _voice.levels.last;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _voice.state == EngineState.capturing) {
          _voice.cancelCapture();
        }
      },
      child: Scaffold(
        backgroundColor: C.bgDeep,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Column(
              children: [
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: C.surface,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: transcribing || !_seenActive
                              ? C.accent
                              : C.rec,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        transcribing
                            ? 'CONVERTING'
                            : !_seenActive
                            ? 'STARTING'
                            : 'REC ${formatDuration(elapsed.inMilliseconds)}',
                        style: mono(12, color: C.textSoft),
                      ),
                    ],
                  ),
                ),
                const Spacer(flex: 2),
                // Shrinks on small screens instead of overflowing.
                Flexible(
                  flex: 8,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _rings(level, transcribing),
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  transcribing ? 'Converting to text…' : 'I’m listening…',
                  style: display(30),
                ),
                const SizedBox(height: 24),
                if (transcribing)
                  const SizedBox(
                    height: 48,
                    child: Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: C.accent,
                        ),
                      ),
                    ),
                  )
                else
                  Waveform(levels: _voice.levels),
                const SizedBox(height: 20),
                Flexible(
                  flex: 4,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 120),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: Text(
                        !_seenActive
                            ? (_voice.status == 'Ready'
                                  ? 'Starting…'
                                  : _voice.status)
                            : _voice.partial.isEmpty
                            ? (_voice.byWake
                                  ? 'Go ahead, say your note.'
                                  : 'Speak now.')
                            : cleanTranscript(_voice.partial)
                                  .replaceAll(RegExp(r'\.$'), '…'),
                        textAlign: TextAlign.center,
                        style: sans(
                          20,
                          height: 1.5,
                          color: !_seenActive && _voice.statusError
                              ? C.danger
                              : _voice.partial.isEmpty
                              ? C.muted
                              : C.text,
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(flex: 3),
                Text(
                  'Saves automatically after ${_secs(services.settings.silenceSecs)} of silence',
                  style: sans(13, color: C.muted),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: PillButton(
                        label: 'Cancel',
                        icon: Ic.close,
                        height: 56,
                        onPressed: transcribing
                            ? null
                            : () {
                                _voice.cancelCapture();
                                _close();
                              },
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: PillButton(
                        label: 'Save now',
                        icon: Ic.check,
                        filled: true,
                        height: 56,
                        onPressed: transcribing ? null : _voice.stopCapture,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _secs(double s) =>
      '${s == s.roundToDouble() ? s.round() : s} second${s == 1 ? '' : 's'}';

  Widget _rings(double level, bool transcribing) {
    return SizedBox(
      width: 240,
      height: 240,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final t = _pulse.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              for (final phase in [0.0, 0.5])
                Opacity(
                  opacity: (1 - ((t + phase) % 1)) * 0.6,
                  child: Container(
                    width: 128 + 112 * ((t + phase) % 1),
                    height: 128 + 112 * ((t + phase) % 1),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF4A3E1C)),
                    ),
                  ),
                ),
              AnimatedScale(
                scale: transcribing ? 1 : 1 + level * 0.12,
                duration: const Duration(milliseconds: 90),
                child: Container(
                  width: 128,
                  height: 128,
                  decoration: const BoxDecoration(
                    color: C.accent,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(color: Color(0x59F5B841), blurRadius: 60),
                    ],
                  ),
                  child: const Icon(Ic.mic, size: 52, color: C.bgDeep),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
