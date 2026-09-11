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
/// fetched itself was a second one, with no name on disk and no limit. So
/// the bytes come through the server whether it has anything to add to them
/// or not, because everything that will ever be added -- a cache behind the
/// read-ahead, a window kept around the play head -- has to be added
/// somewhere both kinds of stream pass through.
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
/// - A loopback URL. That is the embedded server itself or another server
///   on this device. Proxying the first would be the server fetching from
///   itself, and the second already serves the bytes off this device, so a
///   proxied copy would be a second one of them on the same disk. A kept
///   download's URL is one of these -- the server's own media route, off
///   the pieces already on the device.
/// - A URL on the embedded server by any name ([isEmbeddedServer]). The
///   loopback case again, said in terms of the server we were handed
///   rather than of the address family: a stream this server is already
///   serving is not one to give back to it.
/// - Everything, when [serverBase] is null -- a build that started no
///   embedded server. No server means no proxy, and a stream that plays
///   direct is better than one that does not play. Note that a viewer who
///   configured a streaming server elsewhere is *not* this case: the
///   embedded server keeps running and keeps being named, so those streams
///   are proxied like anybody else's.
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
Uri proxiedThroughServer(
  Uri url, {
  required Uri? serverBase,
  String? playerToken,
}) {
  if (serverBase == null) return url;
  if (!url.isScheme('http') && !url.isScheme('https')) return url;
  if (isLoopbackHost(url.host) || isEmbeddedServer(url, serverBase)) {
    return url;
  }

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

/// Whether [url] is on this app's embedded server at [serverBase]: the
/// server's own port, on the server's own host or on any name for this
/// device. False with no embedded server.
///
/// The one rule for "ours", which the player, the proxy and the cast all
/// ask. It used to be spelled per caller, as an exact host and port in
/// one place and as any loopback host in others, and the two disagreed
/// about the same URL: a streaming server typed as `localhost` is the
/// embedded one when the port is, but `localhost` is not `127.0.0.1` as a
/// string, so its streams drew no stats cards. The port is what separates
/// this server from another on the same machine (the standard Stremio
/// server on 11470, say); the host cannot.
bool isEmbeddedServer(Uri url, Uri? serverBase) {
  if (serverBase == null) return false;
  if (!url.isScheme('http') && !url.isScheme('https')) return false;
  if (url.port != serverBase.port) return false;
  return url.host == serverBase.host ||
      (isLoopbackHost(url.host) && isLoopbackHost(serverBase.host));
}

/// Whether [host] names this device -- which is not the same as naming the
/// embedded server: another server can run here too ([isEmbeddedServer]).
bool isLoopbackHost(String host) =>
    host == 'localhost' ||
    (InternetAddress.tryParse(host)?.isLoopback ?? false);
