import 'package:app_links/app_links.dart';

/// The `stremio://` links the platform hands the app: the one it was
/// launched with and every one that arrives while it is up.
///
/// Behind an interface so widget tests can feed links in without a platform
/// channel, the way `ExternalLinkOpener` takes them out.
abstract interface class DeepLinkSource {
  /// The link the app was launched with, null when it was started normally.
  Future<String?> initialLink();

  /// Links delivered while the app is already running (Android's
  /// `onNewIntent`, a second launch handed to the running instance on
  /// desktop). May repeat [initialLink] on the first listen, which the
  /// handler is expected to tolerate.
  Stream<String> links();
}

/// The real source, over `app_links`.
///
/// Links are taken as strings, not as `Uri`s: the manifest URL inside a
/// `stremio://` link is passed to the engine exactly as it arrived, and
/// round-tripping it through `Uri` would be a chance to normalise away a
/// port or a query the addon needs.
class AppLinksDeepLinkSource implements DeepLinkSource {
  AppLinksDeepLinkSource([AppLinks? links]) : _links = links ?? AppLinks();

  final AppLinks _links;

  @override
  Future<String?> initialLink() => _links.getInitialLinkString();

  @override
  Stream<String> links() => _links.stringLinkStream;
}

/// The addon manifest URL a deep link carries, or null when [link] is not
/// one the app acts on.
///
/// The contract is stremio-addons.net's Install button, and every other
/// site's: it takes the addon's own manifest URL and swaps the scheme, so
/// `https://host/manifest.json` arrives as `stremio://host/manifest.json`.
/// The URL is returned **unmodified** — stremio-core's `AddonDetails` does
/// the `stremio://` → `https://` rewrite itself, on the whole URL string,
/// so a port, a path segment carrying a configuration and a query all
/// survive. Rewriting it here would only be a chance to lose one.
///
/// A link with no host (`stremio:///addons`, the app-route form the official
/// clients use for their own navigation) is not a manifest URL and is
/// dropped.
String? deepLinkAddonManifestUrl(String link) {
  final url = Uri.tryParse(link);
  if (url == null || url.scheme != 'stremio' || url.host.isEmpty) return null;
  return link;
}
