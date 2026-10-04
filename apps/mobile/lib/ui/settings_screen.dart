import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../data/settings.dart';
import '../main.dart';
import '../theme.dart';
import '../voice/whisper_download.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings get _s => services.settings;
  bool? _batteryOk;

  @override
  void initState() {
    super.initState();
    _checkBattery();
  }

  Future<void> _checkBattery() async {
    final ok = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (mounted) setState(() => _batteryOk = ok);
  }

  Future<void> _changed() async {
    await _s.save();
    services.voice.settingsChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Row(
              children: [
                Transform.translate(
                  offset: const Offset(-8, 0),
                  child: RoundIconButton(
                    icon: Ic.back,
                    tooltip: 'Back',
                    size: 20,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
                Text('Settings', style: display(28)),
              ],
            ),
            const SizedBox(height: 18),
            const SectionLabel('WAKE WORD'),
            const SizedBox(height: 10),
            _group([
              _switchRow(
                'Listen in background',
                'Keeps working with the screen off',
                _s.wakeEnabled,
                (v) async {
                  await services.voice.setWakeEnabled(v);
                  setState(() {});
                },
              ),
              _row(
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Wake phrase', style: sans(15, weight: 500)),
                    ),
                    Text('“Hey Notes”', style: sans(15, color: C.muted)),
                  ],
                ),
              ),
              _row(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Sensitivity',
                            style: sans(15, weight: 500),
                          ),
                        ),
                        Text(_s.sensitivityLabel, style: mono(13)),
                      ],
                    ),
                    Slider(
                      value: _s.sensitivity,
                      max: 100,
                      label: _s.sensitivityLabel,
                      onChanged: (v) => setState(() => _s.sensitivity = v),
                      onChangeEnd: (_) => _changed(),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Fewer false wakes',
                            style: sans(12, color: C.muted),
                          ),
                        ),
                        Text(
                          'Hears you from further',
                          style: sans(12, color: C.muted),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_batteryOk == false)
                _row(
                  onTap: () async {
                    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
                    _checkBattery();
                  },
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Allow running in background',
                              style: sans(15, weight: 500),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Stops Android from pausing “Hey Notes”',
                              style: sans(13, color: C.muted),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Ic.chevron, color: C.muted),
                    ],
                  ),
                ),
            ]),
            const SizedBox(height: 18),
            const SectionLabel('RECORDING'),
            const SizedBox(height: 10),
            _group([
              _row(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Stop after silence', style: sans(15, weight: 500)),
                    const SizedBox(height: 12),
                    _segmented(),
                  ],
                ),
              ),
              _switchRow(
                'Beep when I wake up',
                'A short tone after “Hey Notes”',
                _s.beep,
                (v) {
                  _s.beep = v;
                  _changed();
                },
              ),
              _switchRow(
                'Keep audio with note',
                'So you can replay what you said',
                _s.keepAudio,
                (v) {
                  _s.keepAudio = v;
                  _changed();
                },
              ),
            ]),
            const SizedBox(height: 18),
            const SectionLabel('TRANSCRIPTION'),
            const SizedBox(height: 10),
            _group([_whisperRow()]),
            const SizedBox(height: 24),
            Text(
              'Everything runs on this phone. Your voice and notes never leave it.',
              style: sans(13, color: C.muted, height: 1.45),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _group(List<Widget> rows) {
    return Container(
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, thickness: 1, color: C.border),
            rows[i],
          ],
        ],
      ),
    );
  }

  Widget _row({required Widget child, VoidCallback? onTap}) {
    final content = Padding(padding: const EdgeInsets.all(16), child: child);
    return onTap == null ? content : InkWell(onTap: onTap, child: content);
  }

  Widget _switchRow(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return MergeSemantics(
      child: _row(
        onTap: () => onChanged(!value),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: sans(15, weight: 500)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: sans(13, color: C.muted)),
                ],
              ),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }

  Widget _segmented() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: C.bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (final v in AppSettings.silenceOptions)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: SizedBox(
                  height: 40,
                  child: TextButton(
                    onPressed: () {
                      _s.silenceSecs = v;
                      _changed();
                    },
                    style: TextButton.styleFrom(
                      backgroundColor: _s.silenceSecs == v
                          ? C.text
                          : Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      '${v == v.roundToDouble() ? v.round() : v} s',
                      style: sans(
                        14,
                        weight: _s.silenceSecs == v ? 600 : 400,
                        color: _s.silenceSecs == v ? C.bg : C.textSoft,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _whisperRow() {
    final w = services.whisper;
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) {
        final (title, subtitle) = switch (w.status) {
          WhisperStatus.ready => (
            'Accurate (Whisper)',
            'On-device · works offline · tuned for accents',
          ),
          WhisperStatus.downloading => (
            'Downloading Whisper… ${(w.progress * 100).round()}%',
            'Keep the app open until it finishes',
          ),
          WhisperStatus.failed => ('Download failed', w.error ?? 'Try again'),
          WhisperStatus.missing => (
            'Fast (on-device)',
            'Get Whisper for better accuracy · ${WhisperDownload.sizeLabel}',
          ),
        };
        return _row(
          onTap:
              w.status == WhisperStatus.missing ||
                  w.status == WhisperStatus.failed
              ? w.start
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: sans(15, weight: 500)),
                        const SizedBox(height: 2),
                        Text(subtitle, style: sans(13, color: C.muted)),
                      ],
                    ),
                  ),
                  if (w.status == WhisperStatus.ready)
                    const Icon(Ic.check, color: C.ok)
                  else if (w.status != WhisperStatus.downloading)
                    const Icon(Ic.download, color: C.accent),
                ],
              ),
              if (w.status == WhisperStatus.downloading) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: w.progress,
                  color: C.accent,
                  backgroundColor: C.faint,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
