import 'package:flutter/material.dart';

import '../../core/core.dart';

/// What the embedded server's storage costs, and the one way there is to
/// ask it to reclaim some.
///
/// This is the first screen to look at when a cache well past its limit is
/// what a cleaner reclaiming nothing looks like: the same cache-vs-limit
/// number is in the copied diagnostics header (alongside the device's free
/// space, which lives there and not here); this is where it can be watched
/// and acted on. Cleaning no longer stops playback -- the server can sweep
/// its cache on request now -- so the action needs no confirmation.
class ServerStorageScreen extends StatefulWidget {
  const ServerStorageScreen({super.key, this.client = const ServerClient()});

  /// Where the numbers come from and what a clean is asked of; widget
  /// tests hand over a fake rather than reaching a real server.
  final ServerCacheControl client;

  @override
  State<ServerStorageScreen> createState() => _ServerStorageScreenState();
}

class _ServerStorageScreenState extends State<ServerStorageScreen> {
  CacheUsage? _usage;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  /// Reads [CacheUsage]. Called on open, after a clean and on an explicit
  /// refresh -- never on a timer: the walk behind it costs one `stat` per
  /// file currently in the cache and is not bounded server-side.
  Future<void> _read() async {
    setState(() => _busy = true);
    try {
      final usage = await widget.client.cacheUsage();
      if (!mounted) return;
      setState(() {
        _usage = usage;
        _error = null;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _usage = null;
        _error = '$error';
        _busy = false;
      });
    }
  }

  /// Runs one eviction pass and reports honestly what happened: bytes
  /// freed when the pass reclaimed something, and -- when the cache is
  /// still over its limit afterwards -- that a live stream or a kept
  /// download is holding what is left, never "clean failed" (nothing here
  /// can fail short of the server not running).
  Future<void> _clean() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final report = await widget.client.cleanCacheNow();
      messenger.showSnackBar(SnackBar(content: Text(_cleanMessage(report))));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not clean: $error')),
      );
    }
    if (!mounted) return;
    await _read();
  }

  String _cleanMessage(EvictionReport report) {
    if (report.freed > 0) {
      final files = report.deleted == 1 ? 'file' : 'files';
      return 'Freed ${DownloadView.humanSize(report.freed)} '
          'from ${report.deleted} $files.';
    }
    if (report.stillOverLimit) {
      return 'Nothing more can be freed right now -- a live stream or a '
          'download you kept is holding '
          '${DownloadView.humanSize(report.protected)}.';
    }
    return 'Nothing needed cleaning.';
  }

  @override
  Widget build(BuildContext context) {
    final usage = _usage;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Server storage'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _read,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (usage == null)
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('Storage unavailable'),
              subtitle: Text(_error ?? 'Reading…'),
            )
          else
            _Row(
              icon: Icons.folder_outlined,
              title: 'Torrent cache',
              value: usage.label,
              detail: usage.protectedFiles > 0
                  ? '${DownloadView.humanSize(usage.protectedBytes)} in '
                        '${usage.protectedFiles} '
                        '${usage.protectedFiles == 1 ? 'file' : 'files'} '
                        'protected: a live stream or a kept download'
                  : 'Nothing protected right now',
              warning: usage.overLimit
                  ? (usage.nothingEvictable
                        ? 'Over its limit, and nothing is evictable right '
                              'now.'
                        : 'Over its limit.')
                  : null,
            ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _busy || usage == null ? null : _clean,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('Clean cache now'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'The server sweeps its cache by itself about a minute after '
              'the last write to it, and hourly otherwise. Cleaning now '
              'runs that same sweep on request, without stopping anything '
              'that is playing. A file a live stream is writing or a '
              'download you kept is never touched.',
            ),
          ),
        ],
      ),
    );
  }
}

/// One number with what it means under it.
class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.value,
    required this.detail,
    this.warning,
  });

  final IconData icon;
  final String title;
  final String value;
  final String detail;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = this.warning;
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: theme.textTheme.bodyLarge),
          Text(detail, style: theme.textTheme.bodySmall),
          if (warning != null)
            Text(
              warning,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}
