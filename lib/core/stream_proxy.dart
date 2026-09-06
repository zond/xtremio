/// Sending a stream through our own server instead of straight at its host.
///
/// The player used to fetch a remote stream itself and keep its own copy of
/// the read-ahead, in a cache file nothing could see. There is one cache
/// now and it is the server's, so every stream has to reach the player as a
/// URL on the server: a torrent already is one, and a remote stream becomes
/// one here.
library;

import 'dart:io';

/// [url] as the player should fetch it -- through the streaming server at
/// [serverBase] when it points anywhere else, and unchanged when it is
/// already the server's own.
///
/// **What the extra hop is for.** The server is the one writer on this
/// device the app can see, bound, sweep and answer for; a stream the player
/// fetched itself was a second one, with no name on disk and no limit. So
/// the bytes come through the server whether it has anything to add to them
/// or not, because everything that will ever be added -- a cache behind the
/// read-ahead, a window kept around the play head -- has to be added
/// somewhere both kinds of stream pass through.
///
/// **What it is not, today.** `/proxy` relays: it opens the target with
/// reqwest and streams the answer back, writing nothing to the cache the
/// cleaner walks and fetching again whatever is asked for twice
/// (`server/tests/proxy.rs`, in the stream-server tree `rust/Cargo.toml`
/// pins). A backward seek past the player's memory cache therefore goes
/// back out to the origin. That is the accepted first step rather than the
/// end state, and it is already better than what it replaces: a re-fetch is
/// bounded network, where the old answer was an unbounded, unnameable file
/// on a 4 GB television.
///
/// **Left alone:**
///
/// - Anything that is not `http` or `https` -- an offline `file://`, a
///   `magnet:` the core has not resolved. There is nothing for a proxy to
///   fetch.
/// - A loopback URL. That is the embedded server itself, whatever port it
///   ended up on: a recorded profile says `11470` and the server takes
///   whatever it can bind, so the port is no part of the test. Proxying it
///   would be the server fetching from itself.
/// - A URL already on [serverBase]. A configured remote streaming server
///   serves its own torrents, and its `/proxy` is for the hosts it is not.
/// - Everything, when [serverBase] is null. No server means no proxy, and a
///   stream that plays direct is better than one that does not play.
///
/// The shape is the one stremio-core builds and the server parses: the
/// target's origin percent-encoded into a `d=` path segment, the target's
/// own path and query after it (`server/src/routes/proxy.rs`). Keeping the
/// path rather than folding the whole URL into `d=` is deliberate -- it
/// leaves the file name and its extension visible to ffmpeg's format
/// probing and to anyone reading a log, where an encoded blob shows
/// neither.
///
/// **The escapes are the whole of it, and both ends have to keep them.**
/// A debrid link signs a base64 blob into a path segment and a live-TV
/// addon names a file with a `#` in it, so an escape decoded anywhere
/// along the way is a 403 or a 404 rather than a slow stream. This half
/// writes the path out exactly as it arrived (below); the other half is
/// the server reading the target's path off the request URI rather than
/// off axum's wildcard capture, which is percent-*decoded* -- until it
/// did, `%2F` reached the origin as a path separator, `%3F` began a query
/// and everything from a `%23` on was gone (`proxy_handler`, measured end
/// to end). The `d=` segment survives the same trip: the server parses it
/// with `form_urlencoded`, which reads a bare `+` as a space, and
/// [Uri.encodeComponent] escapes `+` along with everything else that is
/// not unreserved.
///
/// The target's own query rides on the outside, as this request's query,
/// and it may name anything it likes -- including a `d` of its own. That
/// used to be read as the whole target URL (a `400`, or a fetch of the
/// wrong host when the value happened to parse as one); the server now
/// decides the format from the shape of the path, which the target's
/// query cannot reach.
///
/// A fragment is dropped, because a fragment was never part of what a
/// server is asked for: nobody sends one over the wire.
Uri proxiedThroughServer(Uri url, {required Uri? serverBase}) {
  if (serverBase == null) return url;
  if (!url.isScheme('http') && !url.isScheme('https')) return url;
  if (isLoopbackHost(url.host)) return url;
  if (url.host == serverBase.host && url.port == serverBase.port) return url;

  final target = url.removeFragment();
  final origin = '${target.scheme}://${target.authority}';
  final written = target.toString();
  // Dart writes an http(s) URL as its origin followed by the path and the
  // query, so this is the target's path and query with their
  // percent-encoding exactly as it was given to us -- which `Uri.path` and
  // `Uri.pathSegments`, both decoded, are not. A URL that does not start
  // with its own origin is one this cannot take apart safely, and it goes
  // to the player untouched.
  if (!written.startsWith(origin)) return url;
  final rest = written.substring(origin.length);

  final base = serverBase.toString();
  final prefix = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  return Uri.parse('$prefix/proxy/d=${Uri.encodeComponent(origin)}$rest');
}

/// Whether [url] is one this app's server is serving through its `/proxy`
/// route, which is a different claim from being on the server.
///
/// The route relays somebody else's host, so what can be said about the
/// stream behind it is what could be said about that host, and nothing that
/// is true of the server's own torrent reader. `MediaKitEngine.forcesSeekable`
/// is the one that matters: a torrent read through the server waits for a
/// cold offset and never refuses a seek, while a remote host that ignores
/// `Range` really cannot be seeked in. Putting the second behind the first
/// one's address must not lend it the first one's promise.
bool isProxiedByServer(Uri url) {
  final segments = url.pathSegments;
  return segments.isNotEmpty && segments.first == 'proxy';
}

/// Whether [host] names this device, and so the embedded server -- whatever
/// port it managed to bind.
bool isLoopbackHost(String host) =>
    host == 'localhost' ||
    (InternetAddress.tryParse(host)?.isLoopback ?? false);
