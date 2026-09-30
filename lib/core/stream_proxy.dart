/// Sending a stream through our own server instead of straight at its host.
///
/// There is one cache on this device and it is the server's, so every
/// stream has to reach the player as a URL on the server: a torrent
/// already is one, and a remote stream becomes one here. See
/// docs/ARCHITECTURE.md, "Streams, the proxy and the cache".
library;

import 'dart:io';

/// [url] as the player should fetch it -- through the streaming server at
/// [serverBase] when it points anywhere else, and unchanged when it is
/// already the server's own.
///
/// [playerToken] is the name the caller minted for the player this URL is
/// for. It rides in the parameter segment as `p=`, beside `d=`, which
/// makes it a *proxy* parameter: the server strips it and never sends it
/// to the origin, and it carries the token into every line of any playlist
/// it rewrites, so an HLS player's segment fetches are marked with it too.
/// It is what `ProxyStreamControl.closeProxyStreams` addresses -- a name
/// rather than a credential, since the call that uses it is on the
/// server's bearer-protected loopback control API and never on the LAN.
/// Null leaves the URL unmarked, and such a stream can only be waited out.
///
/// **What the extra hop is for.** The server is the one writer on this
/// device the app can see, bound, sweep and answer for; a stream the player
/// fetched directly would be a second one, with no name on disk and no
/// limit. So the bytes come through the server whether it has anything to
/// add to them or not: everything that will ever be added -- a cache
/// behind the read-ahead, a window kept around the play head -- has to be
/// added somewhere both kinds of stream pass through.
///
/// **What the server keeps of it.** `/proxy` caches by byte range
/// (`server/src/proxy_cache.rs`, in the stream-server tree
/// `rust/Cargo.toml` pins): the part of a range it holds is answered off
/// the disk, the origin is asked only for the rest, and a miss streams to
/// the player as it fills. What it holds is kept around the play head by
/// the same retention that keeps a torrent's pieces, which is why the stats
/// panel's cache row has a window for a proxied stream too. So a backward
/// seek past the player's memory cache is answered from this device inside
/// that window, and only a read outside it goes back out to the origin.
///
/// **Left alone:**
///
/// - Anything that is not `http` or `https` -- a `magnet:` the core has not
///   resolved. There is nothing for a proxy to fetch.
/// - A loopback URL ([isEmbeddedServerHost]). That is the embedded server
///   itself -- a torrent, a `/proxy` URL the core built, a Drive file, a
///   kept download, an archive member -- and proxying it would be the
///   server fetching from itself.
/// - Everything, when [serverBase] is null -- a build that started no
///   embedded server. No server means no proxy, and a stream that plays
///   direct is better than one that does not play.
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
/// off axum's wildcard capture, which comes percent-*decoded*: decoded,
/// `%2F` would reach the origin as a path separator, `%3F` would begin a
/// query and everything from a `%23` on would be gone (`proxy_handler`).
/// The `d=` segment survives the same trip: the server parses it
/// with `form_urlencoded`, which reads a bare `+` as a space, and
/// [Uri.encodeComponent] escapes `+` along with everything else that is
/// not unreserved.
///
/// The target's own query rides on the outside, as this request's query,
/// and it may name anything it likes -- including a `d` of its own --
/// harmlessly, because the server decides the format from the shape of the
/// path, which the target's query cannot reach.
///
/// A fragment is dropped, because a fragment was never part of what a
/// server is asked for: nobody sends one over the wire.
Uri proxiedThroughServer(
  Uri url, {
  required Uri? serverBase,
  String? playerToken,
}) {
  if (serverBase == null) return url;
  if (!url.isScheme('http') && !url.isScheme('https')) return url;
  if (isEmbeddedServerHost(url.host)) return url;

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
  // `&`-joined, and read by the server with `form_urlencoded` -- the same
  // shape `h=` and `r=` use, and the reason both halves are escaped as
  // components rather than written out.
  final token = playerToken == null || playerToken.isEmpty
      ? ''
      : '&p=${Uri.encodeComponent(playerToken)}';
  return Uri.parse('$prefix/proxy/d=${Uri.encodeComponent(origin)}$token$rest');
}

/// Whether [url] is one this app's server is serving through its `/proxy`
/// route, which is a different claim from being on the server.
///
/// The route fronts somebody else's host, so what can be said about the
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

/// Whether [host] names this device, and so the embedded server: every
/// loopback URL the app meets is the embedded server's -- a torrent route,
/// a `/proxy` URL the core built, `/drive/stream`, `/downloads/{key}/stream`,
/// an archive route.
///
/// There is no other server on this device as far as the app is concerned.
/// The core's streaming server URL is pinned to the embedded one
/// (`core::pin_to_embedded`), and an addon handing out a loopback link to a
/// server of its own is not something the app supports, so the port is no
/// part of the question: the embedded server binds whatever port it gets.
/// Any name for this device counts, `localhost` as much as `127.0.0.1` or
/// `::1`.
bool isEmbeddedServerHost(String host) =>
    host == 'localhost' ||
    (InternetAddress.tryParse(host)?.isLoopback ?? false);
