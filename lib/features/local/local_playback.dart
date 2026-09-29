/// How a video on this device is played: the stream the player is handed,
/// and the requests a matched one is recorded under.
library;

import '../../core/core.dart';

/// What a local video says it came from, on the player and in a list.
const String localSourceLabel = 'Local';

/// The address a local play is recorded under: the profile's own Local
/// Files addon (`org.stremio.local`), at the loopback address every
/// Stremio profile gives it.
///
/// **stremio-core keeps progress only for a play with a stream request**,
/// and the request names the addon a stream came from -- which it writes
/// down and asks for the next episode's streams. The Local Files addon is
/// the honest name for "a file on this device"; the Rust side answers it
/// itself, with no streams (`local_addon_answer` in `rust/src/env.rs`), so
/// the next-episode fetch costs nothing and finds nothing, and the file for
/// the next episode is found by the app itself. See `driveStreamRequest` for the same arrangement.
const String localTrackingManifestUrl =
    'http://127.0.0.1:11470/local-addon/manifest.json';

/// The stream JSON the player is handed for [file]: its own address, which
/// libmpv opens as it is -- a `content://` one through a file descriptor
/// media_kit opens for it, a `file://` one directly. Never proxied: only
/// `http(s)` goes through the embedded server.
///
/// `behaviorHints.filename` carries the extension, which is how a cast
/// check reads the container off a stream.
Map<String, dynamic> localStreamJson(LocalMediaFile file) => {
  'url': file.uri,
  'name': file.name.isEmpty ? localSourceLabel : file.name,
  'description': localSourceLabel,
  if (file.name.isNotEmpty) 'behaviorHints': {'filename': file.name},
};

/// The stream request a local play of [videoId] is loaded with -- see
/// [localTrackingManifestUrl].
ResourceRequest localStreamRequest({
  required String type,
  required String videoId,
}) => ResourceRequest(
  base: localTrackingManifestUrl,
  path: ResourcePath(resource: 'stream', type: type, id: videoId),
);

/// The meta and stream requests a matched [file] is played under, or null
/// for one nothing matched, which has no title to keep progress on.
({ResourceRequest meta, ResourceRequest stream})? localMatchRequests(
  LocalMediaFile file,
) {
  final match = file.match;
  if (match == null) return null;
  return (
    meta: ResourceRequest(
      base: kCinemetaManifestUrl,
      path: ResourcePath(
        resource: 'meta',
        type: match.type,
        id: match.cinemetaId,
      ),
    ),
    stream: localStreamRequest(
      type: match.type,
      videoId: match.videoId ?? match.cinemetaId,
    ),
  );
}
