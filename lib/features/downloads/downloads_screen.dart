import 'dart:io' show Directory, Platform;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/core.dart';
import '../../widgets/poster_tile.dart';
import '../player/player_screen.dart';
import 'download_labels.dart';
import 'downloads_controller.dart';

/// Everything kept on the device: what it is, how far along, how much room
/// it takes and where it goes.
///
/// The rows come from the registry the Rust side owns, with live progress
/// merged in ([DownloadsController]); every action here is one call on the
/// [DownloadsClient], never HTTP. Deleting asks first, and asks the
/// question that matters -- whether the file goes with the entry -- because
/// the two are separable: the pin can be dropped and the bytes left where
/// they are.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key, this.destinations = platformDestinations});

  /// The directories the destination control offers to choose between. On
  /// Android those are the app's own external storage directories, an SD
  /// card among them; everywhere else there are none to enumerate and a
  /// path is typed instead.
  final Future<List<String>> Function() destinations;

  /// What the destination control offers on this platform.
  static Future<List<String>> platformDestinations() async {
    if (!Platform.isAndroid) return const [];
    final roots = await getExternalStorageDirectories();
    // A subfolder of the app's own external directory: no permission is
    // needed for it, and the torrent folders do not land among whatever
    // else the app keeps there.
    return [
      for (final root in roots ?? const <Directory>[]) '${root.path}/downloads',
    ];
  }

  /// What is on the device for these downloads. A complete one has fetched
  /// its whole length, so this is the same sum either way.
  static int storageUsed(DownloadsRegistry registry) =>
      registry.items.values.fold(0, (total, view) => total + view.downloaded);

  /// Shown in place of the destination when none is set.
  static const String defaultDestinationLabel = 'Default (with the cache)';

  /// Heading of the destination control.
  static const String destinationTitle = 'Where downloads go';

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  DownloadsClient? _client;
  DownloadsController? _downloads;

  /// Where the files go, once the server has been asked; null is the
  /// torrent cache, and [_destinationKnown] tells the two apart.
  String? _destination;
  bool _destinationKnown = false;

  /// The directories to choose between; empty means a path is typed.
  List<String> _destinations = const [];

  final TextEditingController _typed = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = DownloadsScope.of(context);
    if (_client != client) {
      _downloads
        ?..removeListener(_onDownloads)
        ..dispose();
      _client = client;
      _downloads = DownloadsController(client)..addListener(_onDownloads);
      _readDestination();
    }
  }

  @override
  void dispose() {
    _downloads
      ?..removeListener(_onDownloads)
      ..dispose();
    _typed.dispose();
    super.dispose();
  }

  void _onDownloads() {
    if (mounted) setState(() {});
  }

  /// Asks the server where downloads go, and the platform where they could
  /// go. Neither failing is worth an error on screen: without the choices
  /// the control is a text field, and without the answer it reads as the
  /// default.
  Future<void> _readDestination() async {
    final client = _client;
    String? destination;
    try {
      destination = await client?.directory();
    } catch (_) {
      destination = null;
    }
    var destinations = const <String>[];
    try {
      destinations = await widget.destinations();
    } catch (_) {
      destinations = const [];
    }
    if (!mounted) return;
    setState(() {
      _destination = destination;
      _destinationKnown = true;
      _destinations = destinations;
      _typed.text = destination ?? '';
    });
  }

  Future<void> _setDestination(String? path) async {
    final client = _client;
    if (client == null) return;
    try {
      final settings = await client.setDirectory(path);
      if (!mounted) return;
      setState(() => _destination = settings['downloadsDir'] as String?);
      _tell(
        path == null
            ? 'Downloads go back with the cache.'
            : 'Downloads go to $path.',
      );
    } catch (_) {
      if (!mounted) return;
      _tell('That folder cannot be used for downloads.');
    }
  }

  void _tell(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  /// Plays what is on disk. The stream is handed back as the addon gave it,
  /// which is what `Load Player` takes: a complete pinned file is served
  /// off the disk by the same server the stream would have streamed from.
  void _play(DownloadView view) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'player'),
        builder: (_) => PlayerScreen(
          stream: view.stream.json,
          streamRequest: _requestOf(view.streamRequest),
          metaRequest: _requestOf(view.metaRequest),
          subtitlesPath: ResourcePath(
            resource: 'subtitles',
            type: view.type,
            id: view.videoId,
          ),
        ),
      ),
    );
  }

  /// A stored addon request, or null when it was not stored (or was stored
  /// by a build that shaped it differently).
  static ResourceRequest? _requestOf(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      return ResourceRequest.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> _delete(DownloadView view) async {
    final client = _client;
    final downloads = _downloads;
    if (client == null || downloads == null) return;
    final deleteFiles = await showDialog<bool>(
      context: context,
      builder: (_) => _DeleteDialog(view: view),
    );
    if (deleteFiles == null || !mounted) return;
    DownloadRemoveResult? result;
    try {
      result = await client.remove(view.key, deleteFiles: deleteFiles);
    } catch (_) {
      if (mounted) _tell('This download could not be removed.');
    }
    await downloads.refresh();
    if (result == null || !mounted) return;
    _tell(switch (result) {
      // One torrent offered under two titles: the row goes, the bytes
      // belong to the other download.
      DownloadRemoveResult(removed: true, unpinned: false) =>
        'Removed. The file stays: another download uses it.',
      DownloadRemoveResult(deletedFiles: true) => 'Deleted ${view.name}.',
      _ => 'Removed ${view.name} from downloads.',
    });
  }

  Future<void> _retry(DownloadView view) async {
    final client = _client;
    final downloads = _downloads;
    if (client == null || downloads == null) return;
    DownloadAddResult? result;
    try {
      result = await client.add(DownloadRequest.fromView(view));
    } catch (_) {
      if (mounted) _tell('This download could not be started again.');
    }
    await downloads.refresh();
    if (!mounted) return;
    final failure = result?.error;
    if (failure != null) _tell(downloadFailureMessage(failure));
  }

  @override
  Widget build(BuildContext context) {
    final downloads = _downloads;
    final registry = downloads?.registry ?? DownloadsRegistry.empty;
    final items = registry.newestFirst;
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: ListView(
        children: [
          _StorageHeader(registry: registry),
          _DestinationControl(
            destination: _destination,
            isKnown: _destinationKnown,
            choices: _destinations,
            typed: _typed,
            onSelect: _setDestination,
          ),
          const Divider(height: 1),
          if (downloads != null && downloads.isLoaded && items.isEmpty)
            const _NothingDownloaded(),
          for (final view in items)
            _DownloadRow(
              view: view,
              onPlay: view.isComplete ? () => _play(view) : null,
              onDelete: () => _delete(view),
              onRetry: view.state == DownloadState.error
                  ? () => _retry(view)
                  : null,
            ),
        ],
      ),
    );
  }
}

/// How much of the device these downloads take, and how many there are.
class _StorageHeader extends StatelessWidget {
  const _StorageHeader({required this.registry});

  final DownloadsRegistry registry;

  /// `3 downloads · 4.2 GB on this device`.
  static String label(DownloadsRegistry registry) {
    final count = registry.length;
    final used = DownloadView.humanSize(DownloadsScreen.storageUsed(registry));
    return '${count == 1 ? '1 download' : '$count downloads'} · '
        '$used on this device';
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.sd_storage_outlined),
    title: const Text('Storage'),
    subtitle: Text(label(registry)),
  );
}

/// Where the files go: a choice of directories where the platform has them
/// (Android), a typed path where it does not.
class _DestinationControl extends StatelessWidget {
  const _DestinationControl({
    required this.destination,
    required this.isKnown,
    required this.choices,
    required this.typed,
    required this.onSelect,
  });

  final String? destination;

  /// Whether the server has been asked yet; before that "default" would be
  /// a guess.
  final bool isKnown;
  final List<String> choices;
  final TextEditingController typed;

  /// Null puts them back with the cache.
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final subtitle = !isKnown
        ? 'Asking the server…'
        : destination ?? DownloadsScreen.defaultDestinationLabel;
    if (choices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              DownloadsScreen.destinationTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(
              controller: typed,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                labelText: 'Folder',
                hintText: '/media/downloads',
              ),
              onSubmitted: (path) =>
                  onSelect(path.trim().isEmpty ? null : path.trim()),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: () {
                    final path = typed.text.trim();
                    onSelect(path.isEmpty ? null : path);
                  },
                  child: const Text('Use this folder'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    typed.clear();
                    onSelect(null);
                  },
                  child: const Text('Use the default'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: const Text(DownloadsScreen.destinationTitle),
      subtitle: Text(subtitle),
      // The empty path stands for the default: a `PopupMenuButton` reads a
      // null selection as a dismissed menu and never reports it.
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.edit_outlined),
        tooltip: DownloadsScreen.destinationTitle,
        onSelected: (choice) => onSelect(choice.isEmpty ? null : choice),
        itemBuilder: (context) => [
          const PopupMenuItem<String>(
            value: '',
            child: Text(DownloadsScreen.defaultDestinationLabel),
          ),
          for (final choice in choices)
            PopupMenuItem<String>(value: choice, child: Text(choice)),
        ],
      ),
    );
  }
}

enum _RowAction { play, retry, delete }

/// One download: poster, what it is, how far along, and the actions.
class _DownloadRow extends StatelessWidget {
  const _DownloadRow({
    required this.view,
    required this.onPlay,
    required this.onDelete,
    required this.onRetry,
  });

  final DownloadView view;

  /// Null until the file is whole: there is nothing to play off the disk.
  final VoidCallback? onPlay;
  final VoidCallback onDelete;

  /// Null unless the download stopped.
  final VoidCallback? onRetry;

  /// `Downloaded · 1.4 GB`, or what is on disk of what there is, or the
  /// server's reason it stopped.
  static String status(DownloadView view) {
    final state = downloadStateLabel(view);
    final error = view.error;
    if (view.state == DownloadState.error && error != null) {
      return '$state · $error';
    }
    if (view.isComplete) return '$state · ${view.sizeLabel}';
    return '$state · ${view.downloadedLabel} of ${view.sizeLabel}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      isThreeLine: true,
      leading: SizedBox(
        width: 40,
        height: 60,
        child: PosterImage(url: view.poster),
      ),
      title: Text(view.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          LinearProgressIndicator(value: view.progress ?? 0),
          const SizedBox(height: 4),
          Text(status(view), style: theme.textTheme.bodySmall),
        ],
      ),
      onTap: onPlay,
      trailing: PopupMenuButton<_RowAction>(
        tooltip: 'Download actions',
        onSelected: (action) => switch (action) {
          _RowAction.play => onPlay?.call(),
          _RowAction.retry => onRetry?.call(),
          _RowAction.delete => onDelete(),
        },
        itemBuilder: (context) => [
          if (onPlay != null)
            const PopupMenuItem(value: _RowAction.play, child: Text('Play')),
          if (onRetry != null)
            const PopupMenuItem(value: _RowAction.retry, child: Text('Retry')),
          const PopupMenuItem(value: _RowAction.delete, child: Text('Delete')),
        ],
      ),
    );
  }
}

/// Asks what a removal should do with the bytes. Popping `true` deletes
/// them, `false` keeps them, nothing at all cancels.
class _DeleteDialog extends StatelessWidget {
  const _DeleteDialog({required this.view});

  final DownloadView view;

  static const String keepLabel = 'Keep the file';
  static const String deleteLabel = 'Delete the file';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Remove ${view.name}?'),
    content: Text(
      'It stops being kept for offline playback. The '
      '${view.downloadedLabel} already downloaded can go with it, or stay '
      'as ordinary cache.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text(keepLabel),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text(deleteLabel),
      ),
    ],
  );
}

class _NothingDownloaded extends StatelessWidget {
  const _NothingDownloaded();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Icon(
            Icons.download_outlined,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text('Nothing downloaded', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Open a title, pick a torrent stream and press download to keep '
            'it on this device.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
