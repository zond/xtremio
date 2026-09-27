part of 'meta_details_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// Identifies one stream of one video while its pin is in flight. The
/// state is reloaded while the call runs, so the tile the user tapped is
/// a different widget by the time it comes back.
///
/// **A torrent, a link or a Drive file has one.** A torrent is keyed by
/// its info hash and file index, a link by its URL, a linked Drive file
/// by its `xtremio-drive:` URL; every other stream of a video shares
/// `$videoId|null|null` -- which is harmless only because
/// [StreamDownloads.starter] refuses anything else and so no such pin
/// is ever in flight.
String _streamKey(String videoId, StreamInfo stream) =>
    '$videoId|${stream.infoHash ?? stream.url}|${stream.fileIdx}';

/// Taking a source offline from this screen, and removing it again.
extension _MetaDetailsDownloads on _MetaDetailsScreenState {
  /// The download of one video, whatever source it was taken from. The
  /// registry is keyed by meta and video, so there is at most one, and a
  /// stream tile reads it two ways: as *its* download when the sources
  /// match, and as the download it would replace when they do not.
  DownloadView? _videoDownload(String videoId) =>
      _downloads?.forVideo(widget.id, videoId);

  /// Pins [stream] as an offline download of the selected video.
  ///
  /// Nothing is dispatched to the core: see the class comment on why the
  /// title stays out of the library, and how offline progress is recorded
  /// without it.
  ///
  /// A download of the same video from another release, finished or not,
  /// is asked about first: the pin replaces it, and the Rust side deletes
  /// what it had. Nothing undoes that, so it is not something a stray tap
  /// gets to do -- and the button itself is an ordinary download button,
  /// so this question is the only place the replacement is said.
  /// [group] is null for a linked Drive file, which has no addon request to
  /// record the pin against: the row carries [driveStreamRequest] instead,
  /// so a play of the download keeps progress the way a streamed Drive play
  /// does.
  Future<void> _download(
    MetaDetailsState state,
    MetaItem meta,
    StreamGroup? group,
    StreamInfo stream,
  ) async {
    final client = _downloadsClient;
    final downloads = _downloads;
    if (client == null || downloads == null) return;
    final videoId = state.streamPath?.id ?? meta.id;
    // Asked before the tile goes busy: the dialog is modal, so it is the
    // guard against a second press while it stands, and a cancelled one
    // leaves the tile exactly as it was.
    final replaced = downloads.forVideo(widget.id, videoId);
    if (replaced != null && !replaced.stream.isSameSource(stream)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _ReplaceDialog(replaced: replaced),
      );
      if (confirmed != true || !mounted) return;
    }
    final key = _streamKey(videoId, stream);
    if (!_pending.add(key)) return;
    setState(() {});
    final request = DownloadRequest(
      metaId: widget.id,
      videoId: videoId,
      type: widget.type,
      name: downloadName(meta, state.selectedVideo),
      poster: meta.poster,
      stream: stream,
      meta: meta.json,
      streamRequest:
          (group?.request ??
                  (isDriveStream(stream)
                      ? driveStreamRequest(type: widget.type, videoId: videoId)
                      : null))
              ?.toJson(),
      metaRequest: state.metaRequest?.toJson(),
    );

    DownloadAddResult? result;
    Object? thrown;
    try {
      result = await client.add(request);
    } catch (error) {
      thrown = error;
    }
    if (!mounted) return;
    // The guard is held over the refresh as well: until the fresh listing
    // has the entry, the tile has nothing to show for the pin and would
    // offer the download again.
    await downloads.refresh();
    if (!mounted) return;
    setState(() => _pending.remove(key));

    if (thrown != null) {
      _tell('This stream could not be downloaded.');
      return;
    }
    final failure = result!.error;
    if (failure != null) {
      _tell(downloadFailureMessage(failure));
      return;
    }
    _tell('Downloading ${request.name}');
  }

  /// Drops the download of [entry], and its bytes, once the user has
  /// confirmed -- the Downloads list's own question, asked here so the tile
  /// that started a download is the tile that undoes it.
  ///
  /// The dialog is modal, so it is the guard against a second press while
  /// it stands, and a dismissed one removes nothing.
  Future<void> _deleteDownload(DownloadView entry) async {
    final client = _downloadsClient;
    final downloads = _downloads;
    if (client == null || downloads == null) return;
    if (!await askToRemoveDownload(context, entry) || !mounted) return;
    DownloadRemoveResult? result;
    try {
      result = await client.remove(entry.key, deleteFiles: true);
    } catch (_) {
      if (mounted) _tell('This download could not be removed.');
    }
    // The tiles read the registry, so they only stop saying the title is
    // kept once the fresh listing is in.
    await downloads.refresh();
    if (result == null || !mounted) return;
    _tell(downloadRemovedMessage(result, entry));
  }
}

/// Asks before a download replaces a finished one of the same video taken
/// from another release. Popping `true` goes ahead; the file that is on
/// the device is deleted by the Rust side as the new pin is taken, and
/// there is no undo, which is why it is named here.
class _ReplaceDialog extends StatelessWidget {
  const _ReplaceDialog({required this.replaced});

  final DownloadView replaced;

  static const String replaceLabel = 'Replace it';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Replace ${replaced.name}?'),
    content: Text(
      replaced.isComplete
          ? 'It is already downloaded from another source. Downloading this '
                'stream deletes those ${replaced.sizeLabel} and starts again '
                'from nothing.'
          : 'It is already being downloaded from another source '
                '(${replaced.downloadedLabel} so far). Downloading this stream '
                'stops that download, deletes what it has, and starts again '
                'from nothing.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text(replaceLabel),
      ),
    ],
  );
}
