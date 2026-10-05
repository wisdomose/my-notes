import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../theme.dart';
import '../util/log_file.dart';
import 'widgets.dart';

/// What the voice service has been doing. Meant for screenshots when
/// something doesn't work.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final _voice = services.voice;

  @override
  void initState() {
    super.initState();
    _voice.addListener(_changed);
    _voice.refresh();
    _changed();
  }

  @override
  void dispose() {
    _voice.removeListener(_changed);
    super.dispose();
  }

  /// The saved log (it survives the app being killed), newest first.
  List<String> _lines = [];

  Future<void> _changed() async {
    final lines = await LogFile.read();
    if (mounted) setState(() => _lines = lines.reversed.toList());
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  RoundIconButton(
                    icon: Ic.back,
                    tooltip: 'Back',
                    size: 20,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(child: Text('Diagnostics', style: display(26))),
                  RoundIconButton(
                    icon: Ic.copy,
                    tooltip: 'Copy log',
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: _lines.reversed.join('\n')),
                      );
                      if (context.mounted) showError(context, 'Log copied');
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Text(
                'Service: ${_voice.serviceRunning ? 'running' : 'stopped'} · '
                'engine: ${_voice.engineReady ? 'ready' : 'not ready'} · '
                'state: ${_voice.state.name}\nStatus: ${_voice.status}',
                style: mono(
                  13,
                  color: _voice.statusError ? C.danger : C.textSoft,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: PillButton(
                      label: 'Ping service',
                      height: 44,
                      onPressed: _voice.refresh,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PillButton(
                      label: 'Restart engine',
                      height: 44,
                      filled: true,
                      fill: C.accent,
                      onPressed: _voice.restartService,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: C.card,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: lines.isEmpty
                    ? Center(child: Text('Nothing logged yet', style: mono(13)))
                    : ListView.builder(
                        itemCount: lines.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: SelectableText(
                            lines[i],
                            style: mono(
                              12,
                              color:
                                  lines[i].contains('ERROR') ||
                                      lines[i].contains('FAILED') ||
                                      lines[i].contains('failed')
                                  ? C.danger
                                  : C.textSoft,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
