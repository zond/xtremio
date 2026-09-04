import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../widgets/poster_tile.dart';
import '../../widgets/tv_text_field.dart';
import '../player/player_screen.dart';
import 'destination.dart';
import 'download_labels.dart';
import 'downloads_controller.dart';
import 'offline_play.dart';
import 'remove_download_dialog.dart';

/// Everything kept on the device: what it is, how far along, how much room
/// it takes and where it goes.
///
/// The rows come from the registry the Rust side owns, with live progress
/// merged in ([DownloadsController]); every action here is one call on the
/// [DownloadsClient], never HTTP. Deleting asks first, and asks the
/// question that matters -- whether the file goes with the entry -- because
/// the two are separable: the pin can be dropped and the bytes left where
/// they are.
///
/// Play opens the file itself (`offline_play.dart`), with no server and no
/// network in the way, and falls back to streaming -- saying so -- when the
/// file is not there any more.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({
    super.key,
    this.destinations = platformDownloadDestinations,
    this.canPlay = true,
  });

  /// The name this screen's route carries, so something outside the tree
  /// -- the downloads notification -- can tell whether it is already up
  /// rather than stacking a second one over it.
  static const String routeName = 'downloads';

  /// The route every way in pushes, named so [routeName] means something.
  static Route<void> route({bool canPlay = true}) => MaterialPageRoute<void>(
    settings: const RouteSettings(name: routeName),
    builder: (_) => DownloadsScreen(canPlay: canPlay),
  );

  /// Whether a finished download can be played from here.
  ///
  /// False when the list is opened from a running player: a second
  /// [PlayerScreen] would load the same shared `player` field and start an
  /// engine of its own beside the one still playing. From there the list is
  /// for seeing what is kept and removing some of it, and the row keeps
  /// only the actions that do not open a player.
  final bool canPlay;

  /// The directories the destination control offers to choose between. On
  /// Android those are the app's own external storage directories, an SD
  /// card among them; everywhere else there are none to enumerate and a
  /// path is typed instead.
  final Future<List<String>> Function() destinations;

  /// What is on the device for these downloads. A complete one has fetched
  /// its whole length, so this is the same sum either way.
  ///
  /// Summed over distinct files, not over rows: one torrent file offered
  /// under two metas is two downloads and one file on the disk, which is
  /// the same reason a removal can report `unpinned: false`.
  static int storageUsed(DownloadsRegistry registry) {
    final counted = <String>{};
    var total = 0;
    for (final view in registry.items.values) {
      if (counted.add('${view.infoHash}:${view.fileIdx}')) {
        total += view.downloaded;
      }
    }
    return total;
  }

  /// Shown in place of the destination when none is set.
  static const String defaultDestinationLabel = 'Default (with the cache)';

  /// Heading of the destination control.
  static const String destinationTitle = 'Where downloads go';

  /// What to say when the folder chosen is not the one in use, and nothing
  /// when it is.
  ///
  /// The server clears a `downloadsDir` it cannot prepare at boot -- a card
  /// that is not in the device -- and start-up puts the chosen folder back
  /// when it can ([applyDefaultDestination]). When it cannot, the folder
  /// stays on record and something else holds the downloads meanwhile,
  /// which is worth a sentence: the row above would otherwise show a folder
  /// nobody picked with nothing to say why.
  static String? destinationMissing(DownloadDestination chosen, String? live) {
    final path = chosen.path;
    if (chosen.kind != DownloadDestinationKind.explicit ||
        path == null ||
        path == live) {
      return null;
    }
    return live == null
        ? '$path is not available. Downloads go with the cache until it is.'
        : '$path is not available. Downloads go to $live until it is.';
  }

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

  /// The rows whose retry is in flight, by [DownloadView.key]. Pinning a
  /// magnet again blocks on its metadata, and nothing on the row moves
  /// until the listing lands, so without this the menu invites a second
  /// press that burns another worker for the same file.
  final Set<String> _retrying = {};

  /// Whether a play is between its tap and its player. Asking the registry
  /// for the file is a round trip and the row stays hit-testable across
  /// it, so without this a second press pushes a second player: each one
  /// loads the shared `player` field and starts an engine of its own, and
  /// the one left underneath keeps its mpv alive and plays the title again
  /// when the top one is backed out of.
  bool _playing = false;

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

  /// Plays the file on the disk, with the addon requests the download was
  /// taken with: those are what keep continue-watching moving while the
  /// player runs offline (`Load Player` needs the stream request to record
  /// progress at all, and the meta request to find the library item -- which
  /// offline comes out of the bucket the download put the title in).
  ///
  /// A row is only offered Play when it is finished, but the file can still
  /// be gone by the time it is pressed: an unplugged volume, or a deletion
  /// from outside the app. Then the addon's own stream is played instead --
  /// through the server, over the network -- and the row says so, rather
  /// than opening a player on a URL with no file behind it.
  ///
  /// A second press while that lookup is out is dropped ([_playing]).
  Future<void> _play(DownloadView view) async {
    final client = _client;
    if (client == null || _playing) return;
    _playing = true;
    try {
      await _pushPlayer(client, view);
    } finally {
      _playing = false;
    }
  }

  Future<void> _pushPlayer(DownloadsClient client, DownloadView view) async {
    final playback = await offlinePlayback(client, view);
    if (!mounted) return;
    final message = playback.message;
    if (message != null) _tell(message);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'player'),
        builder: (_) => PlayerScreen(
          stream: playback.stream ?? view.stream.json,
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
    final deleteFiles = await askToRemoveDownload(context, view);
    if (deleteFiles == null || !mounted) return;
    DownloadRemoveResult? result;
    try {
      result = await client.remove(view.key, deleteFiles: deleteFiles);
    } catch (_) {
      if (mounted) _tell('This download could not be removed.');
    }
    await downloads.refresh();
    if (result == null || !mounted) return;
    _tell(downloadRemovedMessage(result, view));
  }

  Future<void> _retry(DownloadView view) async {
    final client = _client;
    final downloads = _downloads;
    if (client == null || downloads == null) return;
    if (!_retrying.add(view.key)) return;
    setState(() {});
    DownloadAddResult? result;
    Object? thrown;
    try {
      result = await client.add(DownloadRequest.fromView(view));
    } catch (error) {
      thrown = error;
    }
    // Held over the refresh as well: until the fresh listing has the entry
    // the row still reads "Stopped", and offering Retry again would be an
    // invitation to pin the same file twice.
    await downloads.refresh();
    if (!mounted) return;
    setState(() => _retrying.remove(view.key));
    if (thrown != null) {
      _tell('This download could not be started again.');
      return;
    }
    final failure = result?.error;
    _tell(
      failure != null
          ? downloadFailureMessage(failure)
          : 'Downloading ${view.name}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloads = _downloads;
    final registry = downloads?.registry ?? DownloadsRegistry.empty;
    final items = registry.newestFirst;
    // The header counts a listing, so it only speaks when there is one:
    // "0 downloads · 0 B" over a listing that failed is the same lie the
    // empty state below stopped telling.
    final counted =
        downloads != null && downloads.isLoaded && downloads.error == null;
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: ListView(
        children: [
          _StorageHeader(
            registry: counted ? registry : null,
            failed: downloads?.error != null,
          ),
          _DestinationControl(
            destination: _destination,
            chosen: registry.destination,
            isKnown: _destinationKnown,
            choices: _destinations,
            typed: _typed,
            onSelect: _setDestination,
          ),
          const Divider(height: 1),
          // A listing that failed is not an empty one: saying "nothing
          // downloaded" to someone whose disk is full of downloads is a lie,
          // and there would be nothing to do about it.
          if (downloads != null && downloads.error != null)
            _ListingFailed(onRetry: downloads.refresh),
          if (downloads != null &&
              downloads.error == null &&
              downloads.isLoaded &&
              items.isEmpty)
            const _NothingDownloaded(),
          for (final view in items)
            _DownloadRow(
              view: view,
              onPlay: view.isComplete && widget.canPlay
                  ? () => _play(view)
                  : null,
              onDelete: () => _delete(view),
              onRetry: view.state == DownloadState.error
                  ? () => _retry(view)
                  : null,
              isRetrying: _retrying.contains(view.key),
            ),
        ],
      ),
    );
  }
}

/// How much of the device these downloads take, and how many there are --
/// or that this is not known, which is not the same as none.
class _StorageHeader extends StatelessWidget {
  const _StorageHeader({required this.registry, required this.failed});

  /// The listing to count, or null when there is none: before the first
  /// one lands, and after one that failed.
  final DownloadsRegistry? registry;

  /// Whether the last listing failed -- the difference between "not yet"
  /// and "not answerable right now".
  final bool failed;

  /// Shown instead of a count when the listing failed.
  static const String unknownLabel = 'Not known right now';

  /// ... and while the first one is still out.
  static const String waitingLabel = '…';

  /// `3 downloads · 4.2 GB on this device`.
  static String label(DownloadsRegistry registry) {
    final count = registry.length;
    final used = DownloadView.humanSize(DownloadsScreen.storageUsed(registry));
    return '${count == 1 ? '1 download' : '$count downloads'} · '
        '$used on this device';
  }

  @override
  Widget build(BuildContext context) {
    final registry = this.registry;
    return ListTile(
      leading: const Icon(Icons.sd_storage_outlined),
      title: const Text('Storage'),
      subtitle: Text(
        registry != null
            ? label(registry)
            : failed
            ? unknownLabel
            : waitingLabel,
      ),
    );
  }
}

/// Where the files go: a choice of directories where the platform has them
/// (Android), a typed path where it does not.
class _DestinationControl extends StatelessWidget {
  const _DestinationControl({
    required this.destination,
    required this.chosen,
    required this.isKnown,
    required this.choices,
    required this.typed,
    required this.onSelect,
  });

  final String? destination;

  /// What the registry says was answered, which is not always what the
  /// server has: a folder it could not prepare at boot is dropped from the
  /// settings and stays on record here.
  final DownloadDestination chosen;

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
    final missing = isKnown
        ? DownloadsScreen.destinationMissing(chosen, destination)
        : null;
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
            if (missing != null) ...[
              const SizedBox(height: 4),
              Text(
                missing,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            TvTextField(
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
            // A Wrap, not a Row: the two labels do not fit side by side on
            // a phone.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () {
                    final path = typed.text.trim();
                    onSelect(path.isEmpty ? null : path);
                  },
                  child: const Text('Use this folder'),
                ),
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
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(subtitle),
          if (missing != null)
            Text(
              missing,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
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
    required this.isRetrying,
  });

  final DownloadView view;

  /// Null until the file is whole: there is nothing to play off the disk.
  final VoidCallback? onPlay;
  final VoidCallback onDelete;

  /// Null unless the download stopped.
  final VoidCallback? onRetry;

  /// Whether a retry of this row is already on its way.
  final bool isRetrying;

  /// The retry item while one is in flight.
  static const String retryingLabel = 'Retrying…';

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
            PopupMenuItem(
              value: _RowAction.retry,
              enabled: !isRetrying,
              child: Text(isRetrying ? retryingLabel : 'Retry'),
            ),
          const PopupMenuItem(value: _RowAction.delete, child: Text('Delete')),
        ],
      ),
    );
  }
}

/// The listing itself failed -- a broken bridge, since the Rust side
/// answers off the disk when the server cannot be asked. What was listed
/// before (if anything) stays below; this says why nothing newer arrived
/// and offers the only useful action.
class _ListingFailed extends StatelessWidget {
  const _ListingFailed({required this.onRetry});

  final Future<void> Function() onRetry;

  static const String message = 'Downloads could not be read';
  static const String retryLabel = 'Try again';

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(
      Icons.cloud_off_outlined,
      color: Theme.of(context).colorScheme.error,
    ),
    title: const Text(message),
    subtitle: const Text('The app could not ask what is kept on this device.'),
    trailing: TextButton(
      onPressed: () => onRetry(),
      child: const Text(retryLabel),
    ),
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
