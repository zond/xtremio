import 'package:flutter/material.dart';

import '../../core/core.dart';

/// What the embedded server's storage costs, and the one way there is to
/// ask it to reclaim some.
///
/// This is the first screen to look at when playback misbehaves on a device
/// nobody can attach a debugger to: bytes arriving with no progress is what
/// a full disk looks like from the outside, and a cache well past its limit
/// is what a cleaner reclaiming nothing looks like. The same two numbers
/// are in the copied diagnostics header; this is where they can be watched
/// and acted on.
class ServerStorageScreen extends StatefulWidget {
  const ServerStorageScreen({super.key, this.client = const ServerClient()});

  /// Where the numbers come from and what a clean is asked of; widget
  /// tests hand over a fake rather than stopping a real server.
  final ServerCacheControl client;

  @override
  State<ServerStorageScreen> createState() => _ServerStorageScreenState();
}

class _ServerStorageScreenState extends State<ServerStorageScreen> {
  ServerStorage? _storage;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    setState(() => _busy = true);
    try {
      final storage = await widget.client.storage();
      if (!mounted) return;
      setState(() {
        _storage = storage;
        _error = null;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _storage = null;
        _error = '$error';
        _busy = false;
      });
    }
  }

  /// Asks first, because this stops the server: a clean is a restart, and
  /// the media routes go down with it.
  Future<void> _clean() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clean the cache now?'),
        content: const Text(
          'The server has no way to sweep its cache on request, so this '
          'restarts it — which is what makes it sweep. Anything playing '
          'will stop. Offline downloads are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restart and clean'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.client.cleanCache();
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'The server restarted and is sweeping its cache. '
            'Refresh in a moment to see what it reclaimed.',
          ),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not clean: $error')),
      );
    }
    if (!mounted) return;
    await _read();
  }

  @override
  Widget build(BuildContext context) {
    final storage = _storage;
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
          if (storage == null)
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('Storage unavailable'),
              subtitle: Text(_error ?? 'Reading…'),
            )
          else ...[
            _Row(
              icon: Icons.folder_outlined,
              title: 'Torrent cache',
              value: storage.cacheLabel,
              detail: storage.cacheDir,
              warning: storage.overLimit
                  ? 'Over its limit: the server is not reclaiming it.'
                  : null,
            ),
            _Row(
              icon: Icons.sd_storage_outlined,
              title: 'Disk',
              value: storage.cacheVolume.label,
              detail: 'The volume the cache is on',
              fraction: storage.cacheVolume.usedFraction,
            ),
            if (storage.downloadsVolume case final downloads?)
              _Row(
                icon: Icons.download_done_outlined,
                title: 'Downloads volume',
                value: downloads.label,
                detail: downloads.path,
                fraction: downloads.usedFraction,
              ),
          ],
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _busy || storage == null ? null : _clean,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('Clean cache now'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'The server sweeps its cache by itself about a minute after '
              'the last write to it, and hourly otherwise. It offers no '
              'call to sweep on request, so cleaning now restarts it — its '
              'first sweep happens at start-up. Nothing here deletes '
              'anything itself: only the server knows which files a running '
              'playback is writing.',
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
    this.fraction,
  });

  final IconData icon;
  final String title;
  final String value;
  final String detail;
  final String? warning;

  /// How full, `0..1`, when that is known: a bar says "nearly gone" faster
  /// than two numbers do.
  final double? fraction;

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
          if (fraction case final fraction?)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: LinearProgressIndicator(value: fraction),
            ),
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
