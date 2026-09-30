import 'dart:convert';

import '../src/rust/api/media.dart' as rust;

/// The scheme of the URL mpv is handed for a stream played by id:
/// `xtremio://<id>`. libmpv reads it through the protocol
/// `rust/src/mpv_stream.rs` registers on each player's handle, over the
/// embedded server's reader -- no HTTP, no URL of the server's.
const String mediaIdScheme = 'xtremio';

/// The URL mpv is handed for the media id [id].
Uri mediaIdUrl(String id) => Uri(scheme: mediaIdScheme, host: id);

/// The media id [url] names, or null when it is not a [mediaIdScheme] URL.
String? mediaIdOf(Uri? url) {
  if (url == null || !url.isScheme(mediaIdScheme) || url.host.isEmpty) {
    return null;
  }
  return url.host;
}

/// Why the server will not play an id: its `Refusal`, `{refused, message}`.
/// [message] is the server's sentence, written to be shown; [kind] is what
/// code switches on (`torrentUnavailable`, `noSuchFile`, ...).
class MediaRefusal implements Exception {
  const MediaRefusal(this.kind, this.message);

  final String kind;
  final String message;

  @override
  String toString() => message;
}

/// Playing a stream by id: what the player asks of the embedded server so
/// that mpv reads `xtremio://<id>` rather than a URL on the server
/// (stream-server `docs/design/media-pipeline.md` §2.5).
///
/// Behind an interface so the player's widget tests can say which URL was
/// registered and which buffer was set without reaching FFI.
abstract interface class MediaIds {
  /// Registers [streamingUrl] -- the stream URL stremio-core built on the
  /// embedded server -- and answers its id. No I/O; throws when the server
  /// is not running.
  String register(Uri streamingUrl);

  /// Finds out what [id] is -- adds the torrent and chooses its file --
  /// and answers null when it can be read, or why not. Waits as long as
  /// the server does, which for a magnet without its metadata is up to
  /// the server's metadata timeout. Throws when the server is not running.
  Future<MediaRefusal?> resolve(String id);

  /// Records the play mpv's reader over [id] will be: this player's
  /// [token] (`<viewer>.<screen>`) and its read-ahead [buffer]
  /// (`BufferAhead.wire`). Set before mpv is handed the id.
  void setPlay(String id, {required String token, required String buffer});

  /// The viewer changed the read-ahead: the reader open on [id] takes it
  /// at its next seek, and nothing re-opens the player. Throws when the
  /// server holds nothing under [id] or is not running.
  void setBuffer(String id, String buffer);
}

/// [MediaIds] over FFI.
class RustMediaIds implements MediaIds {
  const RustMediaIds();

  @override
  String register(Uri streamingUrl) =>
      rust.mediaRegister(streamingUrl: streamingUrl.toString());

  @override
  Future<MediaRefusal?> resolve(String id) async =>
      refusalOf(jsonDecode(await rust.mediaResolve(id: id)) as Map);

  @override
  void setPlay(String id, {required String token, required String buffer}) =>
      rust.mediaSetPlay(id: id, token: token, buffer: buffer);

  @override
  void setBuffer(String id, String buffer) =>
      rust.mediaSetBuffer(id: id, buffer: buffer);

  /// The refusal in a `media_resolve` answer, or null for a stream that is
  /// read in process. One that is not (`inProcess: false`: an origin that
  /// will not serve ranges) is a refusal here too: a torrent never
  /// answers so, and nothing else is played by id yet.
  static MediaRefusal? refusalOf(Map<dynamic, dynamic> answer) {
    final refused = answer['refused'];
    if (refused is String) {
      return MediaRefusal(refused, '${answer['message'] ?? refused}');
    }
    if (answer['inProcess'] != true) {
      return const MediaRefusal(
        'notInProcess',
        'this stream can only be read forward, over HTTP',
      );
    }
    return null;
  }
}
