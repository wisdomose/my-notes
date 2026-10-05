import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:hey_overlay/hey_overlay.dart';

import '../data/settings.dart';
import '../main.dart';
import '../theme.dart';
import '../util/memory.dart';
import '../voice/model_download.dart';
import '../voice/model_files.dart';
import 'diagnostics_screen.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  AppSettings get _s => services.settings;
  bool? _batteryOk;
  bool? _canDrawOverlay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkSystem();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from a system settings screen: re-check what was allowed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkSystem();
  }

  Future<void> _checkBattery() async {
    final ok = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (mounted) setState(() => _batteryOk = ok);
  }

  Future<void> _checkSystem() async {
    await _checkBattery();
    final draw = await HeyOverlay.canDraw();
    if (mounted) setState(() => _canDrawOverlay = draw);
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
              _switchRow('Listen in background', _s.wakeEnabled, (v) async {
                await services.voice.setWakeEnabled(v);
                setState(() {});
              }),
              _switchRow(
                'Show over other apps',
                _s.overlayEnabled && _canDrawOverlay != false,
                (v) async {
                  _s.overlayEnabled = v;
                  await _changed();
                  if (v && _canDrawOverlay == false) {
                    await HeyOverlay.openPermissionSettings();
                  }
                },
              ),
              _valueRow('Wake phrase', '“Hey Notes”'),
              _row(
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('Sensitivity', style: _title)),
                        Text(_s.sensitivityLabel, style: _value),
                      ],
                    ),
                    Slider(
                      value: _s.sensitivity,
                      max: 100,
                      label: _s.sensitivityLabel,
                      onChanged: (v) => setState(() => _s.sensitivity = v),
                      onChangeEnd: (_) => _changed(),
                    ),
                  ],
                ),
              ),
              if (_batteryOk == false)
                _linkRow('Allow running in background', () async {
                  await FlutterForegroundTask.requestIgnoreBatteryOptimization();
                  _checkBattery();
                }),
            ]),
            const SizedBox(height: 18),
            const SectionLabel('RECORDING'),
            const SizedBox(height: 10),
            _group([
              _row(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Stop after silence', style: _title),
                    const SizedBox(height: 12),
                    _segmented(),
                  ],
                ),
              ),
              _switchRow('Beep on wake', _s.beep, (v) {
                _s.beep = v;
                _changed();
              }),
              _switchRow('Keep audio', _s.keepAudio, (v) {
                _s.keepAudio = v;
                _changed();
              }),
            ]),
            const SizedBox(height: 18),
            const SectionLabel('TRANSCRIPTION'),
            const SizedBox(height: 10),
            _group([
              _engineRow(AppSettings.engineCloud, 'Cloud'),
              for (final m in OfflineModel.values) _modelRow(m),
            ]),
            const SizedBox(height: 18),
            _group([
              _linkRow(
                'Diagnostics',
                () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DiagnosticsScreen(),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  TextStyle get _title => sans(15, weight: 500);
  TextStyle get _value => sans(15, color: C.muted);

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
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: child,
      ),
    );
    return onTap == null ? content : InkWell(onTap: onTap, child: content);
  }

  Widget _switchRow(String title, bool value, ValueChanged<bool> onChanged) {
    return MergeSemantics(
      child: _row(
        onTap: () => onChanged(!value),
        child: Row(
          children: [
            Expanded(child: Text(title, style: _title)),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }

  Widget _valueRow(String title, String value) => _row(
    child: Row(
      children: [
        Expanded(child: Text(title, style: _title)),
        Text(value, style: _value),
      ],
    ),
  );

  Widget _linkRow(String title, VoidCallback onTap) => _row(
    onTap: onTap,
    child: Row(
      children: [
        Expanded(child: Text(title, style: _title)),
        const Icon(Ic.chevron, color: C.muted),
      ],
    ),
  );

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

  /// A selectable transcription option. [trailing] replaces the radio
  /// (Whisper shows a download button until its model is on the phone).
  Widget _engineRow(
    String value,
    String title, {
    Widget? trailing,
    String? detail,
    Future<bool> Function()? canSelect,
  }) {
    final selected = _s.engine == value;
    final selectable = trailing == null;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: _row(
        onTap: selectable
            ? () async {
                if (canSelect != null && !await canSelect()) return;
                _s.engine = value;
                _changed();
              }
            : null,
        child: Row(
          children: [
            Expanded(child: Text(title, style: _title)),
            if (detail != null) Text(detail, style: mono(13)),
            trailing ?? _radio(selected),
          ],
        ),
      ),
    );
  }

  Widget _radio(bool selected) => Container(
    width: 24,
    height: 24,
    margin: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: selected ? C.accent : Colors.transparent,
      border: Border.all(color: selected ? C.accent : C.faint, width: 2),
    ),
    child: selected ? const Icon(Ic.check, size: 16, color: C.bg) : null,
  );

  /// An on-device model: a download button until it's on the phone, a
  /// progress ring while it downloads, then a radio like Cloud.
  /// Refuses a model the phone can't run, with a dialog saying so.
  Future<bool> _supported(OfflineModel model) async {
    final mem = await DeviceMemory.read();
    if (mem == null || model.supportsDevice(mem.total)) return true;
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${model.label} isn’t supported on this phone'),
        content: Text(
          'It needs a phone with at least ${model.minDeviceLabel} of memory.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('OK', style: sans(15, weight: 600, color: C.accent)),
          ),
        ],
      ),
    );
    return false;
  }

  Widget _modelRow(OfflineModel model) {
    final engine = AppSettings.engineFor(model);
    final d = services.downloads[model]!;
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final trailing = switch (d.status) {
          ModelStatus.ready => null,
          ModelStatus.downloading => Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                value: d.progress > 0 ? d.progress : null,
                strokeWidth: 2.5,
                color: C.accent,
                backgroundColor: C.faint,
                semanticsLabel: 'Downloading ${model.label}',
                semanticsValue: '${(d.progress * 100).round()}%',
              ),
            ),
          ),
          ModelStatus.missing || ModelStatus.failed => IconButton(
            tooltip: d.status == ModelStatus.failed
                ? 'Retry download'
                : 'Download ${model.label} (${model.sizeLabel})',
            onPressed: () async {
              if (await _supported(model)) d.start();
            },
            icon: Icon(
              d.status == ModelStatus.failed
                  ? Icons.refresh_rounded
                  : Ic.download,
              color: C.accent,
            ),
          ),
        };
        return _engineRow(
          engine,
          model.label,
          trailing: trailing,
          detail: model.sizeLabel,
          canSelect: () => _supported(model),
        );
      },
    );
  }
}
