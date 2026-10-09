import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';

/// Confirms a full clear of the server's cache, wherever it was asked for:
/// Settings' "Clear the cache" and the Server storage screen. One dialog,
/// so what it says is the same everywhere.
///
/// **A clear stops playback, and the dialog says so first.** Unlike the
/// gentle "Clean cache now" it takes what somebody is using: every torrent
/// that streams is stopped, a player in the middle of a film gets a read
/// error, and the title played last loses the part kept around where it
/// was left. A kept download is the one thing it never touches.
///
/// On a television Cancel is where focus starts, so a press that arrived
/// with the remote still in motion clears nothing. Popping `true`
/// confirms; anything else is a cancel.
class ClearCacheDialog extends StatelessWidget {
  const ClearCacheDialog({super.key});

  static const String title = 'Clear the cache?';
  static const String body =
      'Stops what is streaming and deletes everything cached. Downloads you '
      'kept stay.';
  static const String clearLabel = 'Clear';
  static const String cancelLabel = 'Cancel';

  @override
  Widget build(BuildContext context) {
    final isTv = DeviceScope.isTv(context);
    return AlertDialog(
      title: const Text(title),
      content: const Text(body),
      actions: [
        TextButton(
          autofocus: isTv,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text(clearLabel),
        ),
      ],
    );
  }
}

/// What a clear says it did: `Freed 1.2 GB, stopped 2 torrents`.
String clearCacheMessage(CacheClearReport report) {
  final torrents = report.stopped == 1 ? 'torrent' : 'torrents';
  return 'Freed ${formatBytes(report.freed)}, '
      'stopped ${report.stopped} $torrents';
}

/// Asks with [ClearCacheDialog], clears [client]'s cache on a yes and says
/// what that did in a snackbar. The report, or null for a cancel or a
/// clear that failed (whose snackbar says so).
Future<CacheClearReport?> confirmAndClearCache(
  BuildContext context,
  ServerCacheControl client,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final confirmed =
      await showDialog<bool>(
        context: context,
        builder: (_) => const ClearCacheDialog(),
      ) ??
      false;
  if (!confirmed) return null;
  try {
    final report = await client.clearCache();
    DiagnosticsLog.info(
      'storage',
      'cache cleared: freed ${report.freed} bytes, stopped '
          '${report.stopped} torrents',
    );
    messenger.showSnackBar(SnackBar(content: Text(clearCacheMessage(report))));
    return report;
  } catch (error) {
    DiagnosticsLog.warn('storage', 'cache clear failed (${error.runtimeType})');
    messenger.showSnackBar(
      const SnackBar(content: Text('The cache could not be cleared.')),
    );
    return null;
  }
}

/// Settings' "Clear the cache" row, in the Streaming server section: a
/// plain [ListTile] like its neighbours, so a remote lands on it and the
/// theme floor marks it, and its title and subtitle are what a screen
/// reader -- and the driver -- read.
class ClearCacheTile extends StatelessWidget {
  const ClearCacheTile({super.key, this.client = const ServerClient()});

  /// What the clear is asked of; widget tests hand over a fake.
  final ServerCacheControl client;

  static const String title = 'Clear the cache';
  static const String subtitle =
      'Stops what is streaming and deletes everything cached; downloads '
      'you kept stay';

  @override
  Widget build(BuildContext context) => ListTile(
    key: const ValueKey('setting-clear-cache'),
    leading: const Icon(Icons.delete_sweep_outlined),
    title: const Text(title),
    subtitle: const Text(subtitle),
    onTap: () => confirmAndClearCache(context, client),
  );
}
