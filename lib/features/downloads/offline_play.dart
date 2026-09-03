/// Playing a download from the device instead of streaming it.
///
/// A finished download is a whole file on this disk, so there is nothing for
/// the embedded server -- or the network -- to do: the player is handed a
/// `file://` stream and opens the file. That is the better source even with
/// a connection, so it is preferred whenever there is one.
library;

import '../../core/core.dart';

/// What a screen should play, and what to say about it first.
typedef OfflinePlayback = ({
  /// The stream to hand `PlayerScreen`, or null to play the one the screen
  /// already had (the addon's, through the server).
  Map<String, dynamic>? stream,

  /// A sentence for the user before the player opens, or null when there is
  /// nothing to explain.
  String? message,
});

/// The stream JSON that plays [view]'s file at [url].
///
/// stremio-core passes a non-`magnet:` `Url` stream through untouched
/// (`Stream::convert`), so `player.stream`'s `streaming_url` *is* this
/// `file://` URL and the engine opens the file with nothing in between. It
/// is deliberately a `url` stream rather than the torrent it was downloaded
/// from: a torrent would send the player back to the server, and the
/// start-up overlay keys on `infoHash`, so an offline play would sit behind
/// a "connecting to peers" panel that no peer would ever answer.
///
/// The addon's own `name`, `description` and `subtitles` come along -- the
/// source label reads the same as it did online, and the sidecars belong to
/// the file however it is played -- and so does `behaviorHints.bingeGroup`,
/// because the core decides the next episode's stream with
/// `Stream::is_binge_match`, which only matches when *both* streams carry
/// one: drop it and a downloaded episode never auto-advances, and Details'
/// "continue with last source" tile stops resolving. Everything else is
/// dropped. `behaviorHints.filename` is the file's real name on disk, which
/// is what the player reports as the video parameters and what subtitle
/// addons match on.
Map<String, dynamic> offlineStream(DownloadView view, String url) {
  final stream = view.stream;
  final segments = Uri.parse(url).pathSegments;
  final filename = segments.isEmpty || segments.last.isEmpty
      ? stream.filename
      : segments.last;
  final subtitles = stream.subtitlesJson;
  final bingeGroup = stream.behaviorHints['bingeGroup'];
  final hints = <String, dynamic>{
    'filename': ?filename,
    'bingeGroup': ?bingeGroup,
  };
  return {
    'url': url,
    if (stream.name != null) 'name': stream.name,
    if (stream.description != null) 'description': stream.description,
    if (hints.isNotEmpty) 'behaviorHints': hints,
    if (subtitles.isNotEmpty) 'subtitles': subtitles,
  };
}

/// Asks [client] for [view]'s file and, when there is one, the stream that
/// plays it. Also stamps the entry as played.
///
/// Nothing here throws and nothing here refuses to play: a download whose
/// file went away with its volume falls back to streaming *and says so*,
/// which is the difference between a title that still plays and a player
/// stuck on a dead URL. A bridge that could not answer at all falls back
/// silently -- there is nothing useful to tell anyone about it, and the
/// stream plays either way.
Future<OfflinePlayback> offlinePlayback(
  DownloadsClient client,
  DownloadView view,
) => _open(client, view.key, view);

/// The same for the video [videoId] of [metaId], for a caller that holds no
/// listing to look an entry up in: the registry answers with the entry
/// along with the file, and a video with no finished download is a refusal
/// like any other -- nothing to play from the disk, so play what the caller
/// had.
Future<OfflinePlayback> offlinePlaybackOf(
  DownloadsClient client,
  String metaId,
  String videoId,
) => _open(client, DownloadView.keyFor(metaId, videoId), null);

/// Opens [key], building the stream from [known] when the caller has the
/// entry and from the one the open answered with otherwise.
Future<OfflinePlayback> _open(
  DownloadsClient client,
  String key,
  DownloadView? known,
) async {
  DownloadOpenResult opened;
  try {
    opened = await client.open(key);
  } catch (_) {
    return (stream: null, message: null);
  }
  final url = opened.url;
  final view = known ?? opened.entry;
  if (opened.ok && url != null && view != null) {
    return (stream: offlineStream(view, url), message: null);
  }
  return (
    stream: null,
    message: opened.reason == DownloadOpenFailure.missing
        ? kDownloadGoneMessage
        : null,
  );
}

/// What to say when a finished download's file is not on the device any
/// more -- an unplugged volume, or a deletion from outside the app -- and
/// the title is streamed instead.
const String kDownloadGoneMessage =
    'That download is not on this device any more — streaming it instead.';
