import 'dart:async';

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

  /// The DHT's status, read alongside everything else -- never on a timer
  /// of its own. Null only when the read itself failed, which the report
  /// already covers with `_error`.
  DhtStatus? _dht;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  /// Reads a fresh snapshot.
  ///
  /// The log itself is sync and cheap on the Rust side (a lock and a clone
  /// of a few hundred short strings); what the device is has to be asked
  /// for on Android, over the same channel the TV detection uses, so the
  /// report is built once both have answered. Nothing here is slow enough
  /// to need a spinner of its own.
  Future<void> _read() async {
    final DiagnosticsSnapshot snapshot;
    try {
      snapshot = widget.client.snapshot();
    } catch (error) {
      setState(() {
        _report = null;
        _lines = 0;
        _error = '$error';
      });
      return;
    }
    String osVersion;
    try {
      osVersion = await widget.client.osVersion();
    } catch (error) {
      // A device that will not say what it is does not cost us the log.
      osVersion = 'unknown';
    }
    // Same again for the storage: a server that is not running, or a
    // walk that failed, costs that line and nothing else.
    ServerStorage? storage;
    try {
      storage = await widget.client.storage();
    } catch (error) {
      storage = null;
    }
    // Cheap and synchronous, but still asked for only here -- on open and
    // on an explicit refresh -- and never on a timer of its own.
    DhtStatus? dht;
    try {
      dht = widget.client.dhtStatus();
    } catch (error) {
      dht = null;
    }
    if (!mounted) return;
    setState(() {
      _lines = snapshot.logLines.length;
      _dht = dht;
      _report = formatDiagnostics(
        snapshot: snapshot,
        platform: widget.client.platform,
        osVersion: osVersion,
        storage: storage,
        dht: dht,
        at: widget.now(),
      );
      _error = null;
    });
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
    final dht = _dht;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            onPressed: () => unawaited(_read()),
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
            // Information, never a warning: shown only for the one state
            // worth a curious person's attention (a DHT that never found a
            // node this session), and gone the moment it bootstraps or was
            // never running to begin with. The node counts stay a tap away
            // rather than sitting in the way of the log underneath.
            if (dht != null && dht.unavailable) ...[
              const SizedBox(height: 12),
              _DhtNotice(dht: dht),
            ],
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

/// The one DHT line this screen ever shows: an information card, not a
/// warning, with the node counts a tap away rather than inline.
class _DhtNotice extends StatelessWidget {
  const _DhtNotice({required this.dht});

  final DhtStatus dht;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHigh,
      child: ExpansionTile(
        leading: Icon(Icons.info_outline, color: theme.colorScheme.primary),
        title: Text(DhtStatus.unavailableMessage),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedAlignment: Alignment.centerLeft,
        children: [Text(dht.nodeCounts, style: theme.textTheme.bodySmall)],
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
