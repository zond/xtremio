import 'dart:io';

import '../../core/core.dart';
import 'cast_compatibility.dart';

/// **The URL to hand a receiver so it fetches the stream from its source
/// itself**, or null when the stream has to be relayed through this device
/// (published on the LAN listener) as every cast was before.
///
/// A plain web link the receiver can play as it is gains nothing from the
/// relay: every byte would cross the Wi-Fi twice and the phone would have
/// to stay awake for the length of the film. Nothing is shared for such a
/// stream either way, so the relay's one other reason does not apply. It
/// is answered [opened] -- the link exactly as the core published it --
/// when **every** one of these holds:
///
/// - [stream] is an addon's `url` stream ([StreamKind.url]): not a torrent,
///   an archive, a magnet or anything else the server builds.
/// - [opened] is an `http` or `https` URL with no credentials in it, on a
///   host the receiver could reach on its own: not this device (a route of
///   the embedded server, a kept download), not a private, link-local or
///   loopback address, not a `.local` or single-label name. That leaves out
///   a Drive file (`xtremio-drive:`), a file on this device (`file:`,
///   `content:`) by scheme.
/// - The receiver needs nothing from us to fetch it: no
///   `behaviorHints.proxyHeaders` (request headers it would have to send,
///   which only the server's `/proxy` can), and not `notWebReady` (the addon
///   saying a browser-grade player cannot take the link as it is).
/// - The server resolved it ([resolution]) to a file it reads in process,
///   and **not to the member of an archive or a disc image**: a link to a
///   `.rar` plays the film inside it, which only this device can unwrap.
///   Not resolved yet is not eligible -- nothing has said what it is.
/// - [compatibility] is [CastReady]: the receiver plays the file as it is.
///   A film that needs a rendition is repackaged by this device's server,
///   so it goes the rendition way.
///
/// Anything else is relayed. A link that passes and is refused by the
/// receiver anyway -- a debrid link bound to the phone's address, a 403 --
/// is relayed then, once (the player's `_fallBackFromDirect`).
Uri? directCastUrl({
  required Uri? opened,
  required StreamInfo stream,
  required MediaResolution? resolution,
  required CastCompatibility compatibility,
}) {
  if (compatibility is! CastReady) return null;
  if (stream.kind != StreamKind.url) return null;
  if (opened == null) return null;
  if (!opened.isScheme('http') && !opened.isScheme('https')) return null;
  if (opened.host.isEmpty || opened.userInfo.isNotEmpty) return null;
  if (_isLocalHost(opened.host)) return null;
  final hints = stream.behaviorHints;
  if (hints['proxyHeaders'] != null) return null;
  if (hints['notWebReady'] == true) return null;
  // A refusal is not in process either.
  if (resolution == null || !resolution.inProcess) return null;
  if (resolution.memberName != null) return null;
  return opened;
}

/// Whether [host] names something only this network (or this device) can
/// reach: a receiver handed it might, but the point of a direct cast is a
/// host on the internet, and a LAN server is one the relay serves as well.
bool _isLocalHost(String host) {
  final name = host.toLowerCase();
  final address = InternetAddress.tryParse(name);
  if (address == null) {
    // `localhost` is a single label.
    return name.endsWith('.localhost') ||
        name.endsWith('.local') ||
        name.endsWith('.lan') ||
        name.endsWith('.home.arpa') ||
        !name.contains('.');
  }
  if (address.isLoopback || address.isLinkLocal) return true;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 0 ||
        bytes[0] == 10 ||
        (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] < 128) ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
  // Unique local (fc00::/7), and an IPv4-mapped address judged as the
  // IPv4 address it maps.
  if ((bytes[0] & 0xfe) == 0xfc) return true;
  final mapped =
      bytes.sublist(0, 10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  if (mapped) {
    return _isLocalHost(bytes.sublist(12).join('.'));
  }
  return false;
}
