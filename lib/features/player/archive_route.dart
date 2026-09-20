/// Playing the film inside a container instead of giving up on it.
///
/// [sniffArchive] names a stream mpv could not open: a debrid link that is
/// a `.rar` of a release, a torrent whose one big file is a disc image.
/// Until now that was the end of it -- "this source is a RAR archive,
/// which can't be played". The streaming server reads such a container as
/// *ranges of itself* now (`docs/translated-sources.md` in the
/// stream-server tree): it indexes the container with a handful of small
/// reads, works out which bytes of it are the film's bytes, and serves
/// those. Nothing is extracted and nothing is written, so a member is
/// played exactly as cheaply as a plain file -- and a container whose film
/// is *packed* rather than merely wrapped is refused, with a sentence
/// saying so, because serving it would mean downloading and unpacking the
/// whole thing first.
///
/// This is the half that asks. What it answers with is [ArchiveMember] --
/// play this URL instead -- or [ArchiveRefused], which carries the reason
/// the server gave; `null` means the server could not be asked at all, and
/// the viewer gets [archiveFailure] as before.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'archive_sniff.dart';

/// What the server said about a container that was sent to it.
sealed class ArchiveRouting {
  const ArchiveRouting();
}

/// The film inside the container, as a URL on the streaming server. Playing
/// it is an ordinary ranged read of the container's own bytes.
final class ArchiveMember extends ArchiveRouting {
  const ArchiveMember(this.url);

  final Uri url;

  @override
  String toString() => 'ArchiveMember($url)';
}

/// The server will not serve this container by range, and why.
///
/// [kind] is the server's own word for it (`Refusal::kind` in
/// `server/src/translators/mod.rs`), which is part of the route's contract
/// and stable: `compressed`, `encrypted`, `solid`, `malformed`,
/// `noRandomAccess`, `unsupported` -- plus [unavailable], which is this
/// app's name for the `501` the route answers with `{"error": ...}` rather
/// than `{"refused": ...}`. [message] is the sentence the server wrote for
/// a player to show.
final class ArchiveRefused extends ArchiveRouting {
  const ArchiveRefused({required this.kind, required this.message});

  final String kind;
  final String message;

  /// The kind this app gives a `501`: an origin that will not serve byte
  /// ranges (serving a member out of it would mean downloading the whole
  /// container), or a build with no reader for the format at all. The
  /// route says `{"error": ...}` for both, so the word is ours; the
  /// sentence is still the server's.
  static const String unavailable = 'unavailable';

  @override
  String toString() => 'ArchiveRefused($kind: $message)';
}

/// What a container is, and where: everything [routeArchive] needs.
final class ArchiveRouteRequest {
  /// A container at a web address -- what the player was about to fetch,
  /// [played], which for anybody else's host is already this server's own
  /// `/proxy` URL with the stream's credentials on it. **The URL the
  /// player would have played and not the addon's bare one**: a signed
  /// debrid link, a `h=` header override, a token in a path segment are
  /// all in it, and a container the server cannot fetch is a container it
  /// cannot index.
  const ArchiveRouteRequest.link({
    required this.serverBase,
    required this.kind,
    required Uri played,
  }) : url = played,
       infoHash = null,
       pathInTorrent = null;

  /// A container that is a file of a torrent this server already has.
  /// There is no create call for this one: the key names the torrent and
  /// the file, and the first request for it is what indexes the container.
  /// [pathInTorrent] is the file's name as the server states it
  /// (`streamName` in `stats.json`), which is what the route matches.
  const ArchiveRouteRequest.inTorrent({
    required this.serverBase,
    required this.kind,
    required this.infoHash,
    required this.pathInTorrent,
  }) : url = null;

  /// The embedded server, as `CoreInitInfo` reports it.
  final Uri serverBase;

  /// What the container turned out to be, which says which translator the
  /// server reads it with ([ArchiveKind.serverPrefix]).
  final ArchiveKind kind;

  final Uri? url;
  final String? infoHash;
  final String? pathInTorrent;

  /// The session key the stream routes take. A torrent-backed container
  /// names itself; one behind a link is given a key by `/create`.
  String? get torrentKey {
    final hash = infoHash;
    final path = pathInTorrent;
    if (hash == null || path == null) return null;
    return 'torrent:$hash/$path';
  }
}

/// How the player asks; a function so a widget test can answer without a
/// server.
typedef ArchiveRouter = Future<ArchiveRouting?> Function(
  ArchiveRouteRequest request,
);

/// Asks the server to play the film inside [request]'s container.
///
/// Every failure that is not the server saying no -- no answer, a body
/// that is not what the route documents, a status the route does not use
/// -- is `null`: this only ever improves on giving up, and a failure to
/// improve on it leaves the viewer the message they would have had.
Future<ArchiveRouting?> routeArchive(
  ArchiveRouteRequest request, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await _route(client, request).timeout(timeout);
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<ArchiveRouting?> _route(
  HttpClient client,
  ArchiveRouteRequest request,
) async {
  final String key;
  final torrentKey = request.torrentKey;
  if (torrentKey != null) {
    key = torrentKey;
  } else {
    final created = await _create(client, request);
    if (created is ArchiveRefused) return created;
    if (created is! String) return null;
    key = created;
  }

  // `GET /{fmt}/stream/{key}` answers a redirect to the member the server
  // picked -- the biggest file that is not a sample, by the same
  // `fileIdx`/`fileMustInclude` rule stremio-core's archive streams use.
  // Following it here rather than leaving it to mpv is worth one round
  // trip: what the engine is handed is then a URL ending in the film's own
  // name, which is what ffmpeg's format probing and every log line want.
  final selection = _streamUrl(request, key);
  final answer = await _send(client, 'GET', selection, followRedirects: false);
  final location = answer.headers.value(HttpHeaders.locationHeader);
  final refusal = await _refusalOf(answer);
  if (refusal != null) return refusal;
  if (answer.isRedirect && location != null) {
    return ArchiveMember(selection.resolve(location));
  }
  if (torrentKey == null) return null;

  // A torrent-backed container that got no redirect. The route creates its
  // session on the first request for a *member*, and the redirect handler
  // only looks sessions up -- so as the server stands today (master
  // 52d25dc) nothing indexes the container here and nothing selects a
  // member of it: the answer is a `404`. The query form below does index
  // it, which is what turns a container the server will not serve at all
  // -- a Blu-ray image's metadata partition, a RAR set with a hole in it
  // -- from "can't be played" into the sentence that says why. It cannot
  // produce a member: with nothing selected the route answers `404` for
  // that too. See the step-7 report; the fix is on the server's side.
  final indexed = await _send(
    client,
    'GET',
    _streamUrl(request, key, asQuery: true),
    followRedirects: false,
  );
  return _refusalOf(indexed);
}

/// `POST /{fmt}/create` -- the session key on success, an [ArchiveRefused]
/// when the server says no, null when it could not be asked.
Future<Object?> _create(HttpClient client, ArchiveRouteRequest request) async {
  final url = request.url;
  if (url == null) return null;
  final create = Uri.parse(
    '${_base(request.serverBase)}/${request.kind.serverPrefix}/create',
  );
  final body = utf8.encode(
    jsonEncode({
      'urls': [url.toString()],
    }),
  );
  final send = await client.openUrl('POST', create);
  send.followRedirects = false;
  send.headers.contentType = ContentType.json;
  send.headers.contentLength = body.length;
  send.add(body);
  final answer = await send.close();
  // The status decides which half of the body this is, and the body is
  // read once: a refusal's two fields, or the session key.
  if (answer.statusCode != HttpStatus.ok) return _refusalOf(answer);
  final json = await _json(answer);
  final key = json?['key'];
  return key is String && key.isNotEmpty ? key : null;
}

/// The stream URL for [key]. The key is one path segment, so everything in
/// it is escaped -- including the `/` between a torrent's hash and the
/// container's path inside it, which the route splits on after decoding.
Uri _streamUrl(
  ArchiveRouteRequest request,
  String key, {
  bool asQuery = false,
}) {
  final prefix = '${_base(request.serverBase)}/${request.kind.serverPrefix}';
  return Uri.parse(
    asQuery
        ? '$prefix/stream?key=${Uri.encodeQueryComponent(key)}'
        : '$prefix/stream/${Uri.encodeComponent(key)}',
  );
}

/// [base] without a trailing slash, so a path can be joined onto it.
String _base(Uri base) {
  final written = base.toString();
  return written.endsWith('/')
      ? written.substring(0, written.length - 1)
      : written;
}

Future<HttpClientResponse> _send(
  HttpClient client,
  String method,
  Uri url, {
  required bool followRedirects,
}) async {
  final request = await client.openUrl(method, url);
  request.followRedirects = followRedirects;
  return request.close();
}

/// The refusal [answer] carries, or null when it is not one.
///
/// Two shapes, both from `routes/archive.rs`: `415` (a member this server
/// will not serve by range) and `422` (a container that contradicts
/// itself) carry `{"refused": kind, "message": sentence}`; `501` carries
/// `{"error": sentence}` and no kind, because it is *this server*
/// declining to do the work rather than the container being at fault.
///
/// It always reads the body to its end, whatever the status: the one
/// caller that wants something else off the answer -- the redirect's
/// `Location` -- takes it off the headers before this is called.
Future<ArchiveRefused?> _refusalOf(HttpClientResponse answer) async {
  final status = answer.statusCode;
  final refused =
      status == HttpStatus.unsupportedMediaType ||
      status == HttpStatus.unprocessableEntity;
  if (!refused && status != HttpStatus.notImplemented) {
    await answer.drain<void>();
    return null;
  }
  final json = await _json(answer);
  if (refused) {
    final kind = json?['refused'];
    final message = json?['message'];
    if (kind is! String || message is! String || message.isEmpty) return null;
    return ArchiveRefused(kind: kind, message: message);
  }
  final message = json?['error'];
  if (message is! String || message.isEmpty) return null;
  return ArchiveRefused(kind: ArchiveRefused.unavailable, message: message);
}

/// How much of a body this reads before calling it malformed: every body
/// it reads is a two-field JSON object, and a route that answered a film
/// instead is not one to swallow.
const int _maxBodyBytes = 64 * 1024;

Future<Map<String, dynamic>?> _json(HttpClientResponse answer) async {
  final bytes = <int>[];
  var tooBig = false;
  await for (final chunk in answer) {
    // Read to the end even past the cap, so the connection is finished
    // with rather than abandoned half-read.
    if (tooBig) continue;
    bytes.addAll(chunk);
    tooBig = bytes.length > _maxBodyBytes;
  }
  if (tooBig) return null;
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  } on Object {
    return null;
  }
}

/// What the viewer is told when the server refused the container.
///
/// The server's sentence is the fallback and often the whole answer -- it
/// is written for a player to show, and for `malformed` and `unsupported`
/// it names the one concrete thing (which volume is missing, which UDF
/// structure) that no message written here could know. Where the UI can
/// say it better it does: the four refusals below are *the film is packed*,
/// said four ways, and what a viewer needs from them is that no amount of
/// waiting will help and another source will.
String archiveRefusal(ArchiveKind kind, ArchiveRefused refusal) {
  final said = switch (refusal.kind) {
    'compressed' =>
      'this ${kind.label} has the film packed inside it rather than just '
          'wrapped, so playing it would mean unpacking the whole archive '
          'first',
    'solid' =>
      'this ${kind.label} is packed as one solid block, so the film inside '
          'it cannot be read on its own',
    'encrypted' =>
      'this ${kind.label} is password-protected, and there is nowhere to '
          'ask you for the password',
    'noRandomAccess' =>
      'this ${kind.label} is one compressed stream with no way in at the '
          'middle, so playing it would mean unpacking all of it first',
    _ => refusal.message,
  };
  return '$said. Try another source.';
}
