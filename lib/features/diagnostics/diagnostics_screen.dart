import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import 'diagnostics_report.dart';

/// What the app can say about itself when something went wrong on a device
/// nobody can attach a debugger to.
///
/// The Rust core keeps its last few hundred `tracing` lines in memory --
/// its own and the embedded stream-server's, which share the one
/// subscriber -- and this screen shows them under a short header (build,
/// device, server, the pinned revisions) and copies the lot to the
/// clipboard. Everything shown and copied has been through
/// [redactSecrets]: the server's bearer token, auth keys, passwords and
/// addon manifest paths never leave the process.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    super.key,
    this.client = const RustDiagnosticsClient(),
    this.now = DateTime.now,
  });

  /// Where the report comes from; widget tests hand over a fake instead of
  /// reaching FFI.
  final DiagnosticsClient client;

  /// The clock stamped into the header, so a test can pin it.
  final DateTime Function() now;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  /// The whole report, redacted, or null when it could not be read.
  String? _report;

  /// How many log lines it carries (the header is not one of them).
  int _lines = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _read();
  }

  /// Reads a fresh snapshot. Sync and cheap on the Rust side (a lock and a
  /// clone), so there is nothing to await and nothing to leak.
  void _read() {
    try {
      final snapshot = widget.client.snapshot();
      setState(() {
        _lines = snapshot.logLines.length;
        _report = formatDiagnostics(
          snapshot: snapshot,
          platform: widget.client.platform,
          osVersion: widget.client.osVersion,
          at: widget.now(),
        );
        _error = null;
      });
    } catch (error) {
      setState(() {
        _report = null;
        _lines = 0;
        _error = '$error';
      });
    }
  }

  Future<void> _copy() async {
    final report = _report;
    if (report == null) return;
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: report));
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Copied $_lines log ${_lines == 1 ? 'line' : 'lines'} '
          'to the clipboard.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            onPressed: _read,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              autofocus: true,
              onPressed: report == null ? null : _copy,
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('Copy diagnostics'),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: report == null
                  ? Center(
                      child: Text(
                        'Diagnostics unavailable: ${_error ?? 'unknown'}',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : _LogView(report: report),
            ),
          ],
        ),
      ),
    );
  }
}

/// The report itself, scrollable -- with the arrow keys too, so a remote
/// can read past the first screenful once it moves down off the button.
class _LogView extends StatefulWidget {
  const _LogView({required this.report});

  final String report;

  /// How far one arrow press scrolls.
  static const double step = 160;

  @override
  State<_LogView> createState() => _LogViewState();
}

class _LogViewState extends State<_LogView> {
  final ScrollController _controller = ScrollController();
  bool _focused = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final delta = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => _LogView.step,
      LogicalKeyboardKey.arrowUp => -_LogView.step,
      _ => null,
    };
    if (delta == null || !_controller.hasClients) return KeyEventResult.ignored;
    final position = _controller.position;
    final target = (_controller.offset + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == _controller.offset) return KeyEventResult.ignored;
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: _onKeyEvent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: _focused
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Scrollbar(
          controller: _controller,
          child: SingleChildScrollView(
            controller: _controller,
            padding: const EdgeInsets.all(8),
            child: SelectableText(
              widget.report,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
      ),
    );
  }
}
