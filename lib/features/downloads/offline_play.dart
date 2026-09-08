/// Playing a download from the device instead of fetching it from peers.
///
/// **A finished download is not a file.** Torrent data is stored one file
/// per piece, for the streaming cache and a kept download alike, and the
/// only reader of those pieces is the embedded server. So the player is
/// handed a `url` stream naming that server's media route for this torrent
/// and file, which is served off the pieces already here: no peer, no
/// tracker and no network. That is the better source even with a
/// connection, so it is preferred whenever there is one.
library;

import '../../core/core.dart';

/// The stream JSON that plays [view]'s download at [url].
///
/// stremio-core passes a non-`magnet:` `Url` stream through untouched
/// (`Stream::convert`), so `player.stream`'s `streaming_url` *is* this URL
/// and the engine fetches it with nothing in between. It is deliberately a
/// `url` stream rather than the torrent it was downloaded from, even though
/// the URL now names the same server: a torrent stream sends the player
/// through the engine's own start-up, and the overlay keys on `infoHash`,
/// so a download with every byte on the device would sit behind a
/// "connecting to peers" panel it has no need of.
///
/// The addon's own `name`, `description` and `subtitles` come along -- the
/// source label reads the same as it did online, and the sidecars belong to
/// the file however it is played -- and so does `behaviorHints.bingeGroup`,
/// because the core decides the next episode's stream with
/// `Stream::is_binge_match`, which only matches when *both* streams carry
/// one: drop it and a downloaded episode never auto-advances, and Details'
/// "continue with last source" tile stops resolving. Everything else is
/// dropped. `behaviorHints.filename` is the name the torrent gives the
/// file, which is what the player reports as the video parameters and what
/// subtitle addons match on; it comes from the entry, because the URL's
/// last segment is a file index now and names nothing.
Map<String, dynamic> offlineStream(DownloadView view, String url) {
  final stream = view.stream;
  final name = view.path?.split(RegExp(r'[/\\]')).last;
  final filename = name == null || name.isEmpty ? stream.filename : name;
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

/// The stream that plays [view] off this device, or null to play the one
/// the caller already had (the addon's, through the server). Also stamps
/// the entry as played.
///
/// Nothing here throws and nothing here refuses to play: a download that
/// cannot be played from the device falls back to streaming the addon's own
/// stream, which is the difference between a title that still plays and a
/// player stuck on a dead URL. The fallback is silent -- there is nothing
/// useful to tell anyone about it, and the stream plays either way.
Future<Map<String, dynamic>?> offlinePlayback(
  DownloadsClient client,
  DownloadView view,
) => _open(client, view.key, view);

/// The same for the video [videoId] of [metaId], for a caller that holds no
/// listing to look an entry up in: the registry answers with the entry
/// along with the URL, and a video with no finished download is a refusal
/// like any other -- nothing to play from the device, so play what the
/// caller had.
Future<Map<String, dynamic>?> offlinePlaybackOf(
  DownloadsClient client,
  String metaId,
  String videoId,
) => _open(client, DownloadView.keyFor(metaId, videoId), null);

/// Opens [key], building the stream from [known] when the caller has the
/// entry and from the one the open answered with otherwise.
Future<Map<String, dynamic>?> _open(
  DownloadsClient client,
  String key,
  DownloadView? known,
) async {
  DownloadOpenResult opened;
  try {
    opened = await client.open(key);
  } catch (_) {
    return null;
  }
  final url = opened.url;
  final view = known ?? opened.entry;
  if (opened.ok && url != null && view != null) {
    return offlineStream(view, url);
  }
  return null;
}
