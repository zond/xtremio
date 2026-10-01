import 'dart:convert';

import 'package:flutter/services.dart';

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

/// What the server found an id to be (its `Resolved`), or why it will not
/// play it ([refusal]).
class MediaResolution {
  const MediaResolution({
    this.name,
    this.memberName,
    this.inProcess = true,
    this.proxyUrl,
    this.sniffed = true,
  }) : refusal = null;

  const MediaResolution.refused(MediaRefusal this.refusal)
    : name = null,
      memberName = null,
      inProcess = false,
      proxyUrl = null,
      sniffed = false;

  /// The answer of `media_resolve`, as its JSON decodes.
  factory MediaResolution.fromJson(Map<dynamic, dynamic> json) {
    final refused = json['refused'];
    if (refused is String) {
      return MediaResolution.refused(
        MediaRefusal(refused, '${json['message'] ?? refused}'),
      );
    }
    final member = json['member'];
    final memberName = member is Map ? member['name'] : null;
    final proxyUrl = json['proxyUrl'];
    final name = json['name'];
    return MediaResolution(
      name: name is String && name.isNotEmpty ? name : null,
      memberName: memberName is String && memberName.isNotEmpty
          ? memberName
          : null,
      inProcess: json['inProcess'] == true,
      proxyUrl: proxyUrl is String ? Uri.tryParse(proxyUrl) : null,
      sniffed: json['sniffed'] == true,
    );
  }

  /// Why the server will not play it, or null when it will.
  final MediaRefusal? refusal;

  /// What it is called: the torrent file's name, a link's last segment, a
  /// Drive file's or a local file's name -- the member's, for a container.
  final String? name;

  /// The film inside, when the id turned out to be a container: the
  /// member's path in it. What a cast is judged by, not the container.
  final String? memberName;

  /// Whether this process reads it, through `xtremio://<id>`. False only
  /// for an origin that will not serve ranges (a live playlist): mpv is
  /// handed [proxyUrl] and reads it forward over HTTP.
  final bool inProcess;

  /// The `/proxy` URL on the embedded server for an origin read forward;
  /// null for everything read in process.
  final Uri? proxyUrl;

  /// Whether the server read the file's head for a container signature.
  final bool sniffed;
}

/// Playing a stream by id: what the player asks of the embedded server so
/// that mpv reads `xtremio://<id>` rather than a URL on the server
/// (stream-server `docs/design/media-pipeline.md` §2.5), and what a cast
/// publishes (§2.7).
///
/// Behind an interface so the player's widget tests can say what was
/// registered and published without reaching FFI.
abstract interface class MediaIds {
  /// Registers [streamingUrl] -- a URL on the embedded server: a torrent
  /// the core built, a `/proxy` link, an archive member -- and answers its
  /// id. No I/O; throws when the server is not running.
  String register(Uri streamingUrl);

  /// Registers the linked Google Drive file [fileId] and answers its id;
  /// its grant is the one the account handed Rust. No I/O.
  String registerDrive(String fileId, {String? name});

  /// Registers the file at [path] on this device. No I/O.
  String registerLocalPath(String path, {String? name});

  /// Registers the `content://` document [contentUri] (Android): opened
  /// for reading and its descriptor handed to the server. Throws when it
  /// cannot be opened, and where there are no descriptors to hand over.
  Future<String> registerLocalContent(Uri contentUri, {String? name});

  /// Finds out what [id] is -- adds the torrent and chooses its file,
  /// probes a link, renews a Drive grant, sniffs for a container -- and
  /// answers it, or why it cannot be played. Waits as long as the server
  /// does, which for a magnet without its metadata is up to the server's
  /// metadata timeout. Throws when the server is not running.
  Future<MediaResolution> resolve(String id);

  /// Records the play mpv's reader over [id] will be: this player's
  /// [token] (`<viewer>.<screen>`) and its read-ahead [buffer]
  /// (`BufferAhead.wire`). Set before mpv is handed the id; a cast of the
  /// id carries the same play.
  void setPlay(String id, {required String token, required String buffer});

  /// The viewer changed the read-ahead: the reader open on [id] takes it
  /// at its next seek, and nothing re-opens the player. Throws when the
  /// server holds nothing under [id] or is not running.
  void setBuffer(String id, String buffer);

  /// Publishes [id] for a cast and answers the token the receiver's URL
  /// ends in (`<lan base>/cast/<token>`). **Never log it**: it is a URL into
  /// this device while it is published. Throws while the LAN listener is
  /// down or for an id the server does not hold.
  Future<String> publish(String id);

  /// Ends the publication [token]; a body being served under it is cut.
  Future<bool> unpublish(String token);
}

/// [MediaIds] over FFI, and for a `content://` document the
/// `xtremio/local_media` channel (`LocalMediaChannel.kt`, `openFd`).
class RustMediaIds implements MediaIds {
  const RustMediaIds({
    this.localChannel = const MethodChannel('xtremio/local_media'),
  });

  final MethodChannel localChannel;

  @override
  String register(Uri streamingUrl) =>
      rust.mediaRegister(streamingUrl: streamingUrl.toString());

  @override
  String registerDrive(String fileId, {String? name}) =>
      rust.mediaRegisterDrive(fileId: fileId, name: name);

  @override
  String registerLocalPath(String path, {String? name}) =>
      rust.mediaRegisterLocalPath(path: path, name: name);

  @override
  Future<String> registerLocalContent(Uri contentUri, {String? name}) async {
    final fd = await localChannel.invokeMethod<int>('openFd', {
      'uri': contentUri.toString(),
    });
    if (fd == null || fd < 0) {
      throw const MediaRefusal(
        'openFailed',
        'This file on the device could not be opened.',
      );
    }
    // Rust owns the descriptor from this call on, answered or not.
    return rust.mediaRegisterLocalFd(fd: fd, name: name);
  }

  @override
  Future<MediaResolution> resolve(String id) async => MediaResolution.fromJson(
    jsonDecode(await rust.mediaResolve(id: id)) as Map,
  );

  @override
  void setPlay(String id, {required String token, required String buffer}) =>
      rust.mediaSetPlay(id: id, token: token, buffer: buffer);

  @override
  void setBuffer(String id, String buffer) =>
      rust.mediaSetBuffer(id: id, buffer: buffer);

  @override
  Future<String> publish(String id) => rust.mediaPublish(id: id);

  @override
  Future<bool> unpublish(String token) => rust.mediaUnpublish(token: token);
}
