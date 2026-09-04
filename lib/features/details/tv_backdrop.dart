import 'package:flutter/material.dart';

/// The title's own artwork behind everything on a television, with the
/// scrim that keeps white text and a focus ring readable over it.
///
/// The image fills the panel, overscan band included -- the band is what
/// the *content* keeps clear of, not the picture, so a set that crops the
/// edges crops artwork rather than showing a strip of ground. That is why
/// this is not wrapped in a `SafeArea` and why the details screen does not
/// put it inside `TvSafeArea`, whose band is filled with the scaffold's
/// own colour and would paint over it.
///
/// Three things it has to get right:
///
/// - **The darkening is a scrim over the picture, never opacity on the
///   text.** Dimmed text over a busy frame is unreadable in a way a dimmed
///   picture behind solid text is not, and the picture is the part that may
///   be anything -- a snow field, a white title card. So the whole image is
///   covered by [scrim] and everything above it is drawn at full strength.
/// - **The scrim is a gradient and never a blur.** On the Mali GPU in the
///   Chromecast this app is used on, a full-screen `BackdropFilter` costs
///   frames on every one of them; a gradient is drawn by the same shader
///   that would have filled a flat colour.
/// - **A missing image may never disturb the layout.** [background], then
///   [poster], then the brand ground, and a URL that *fails to load* falls
///   through exactly like one that was never there -- the fallback is the
///   `errorBuilder`, so an image that 404s is answered without a rebuild
///   and without the layout moving under whatever is on top.
///
/// The size asked for is [imageSize]: metahub serves one URL per size and
/// Cinemeta's `poster` is the small one, so a fallback to the poster would
/// otherwise stretch a thumbnail across the whole panel. Only a metahub URL
/// is rewritten ([atSize]); every other addon's URL is passed on untouched.
/// The decode is bounded to the panel's own pixels on top of that, because
/// a backdrop decoded at its native size is several megabytes of texture on
/// a device that has already been seen complaining about buffer formats.
class TvBackdrop extends StatelessWidget {
  const TvBackdrop({
    super.key,
    required this.background,
    required this.poster,
    required this.child,
  });

  /// The 16:9 backdrop the meta addon sent, when it sent one.
  final String? background;

  /// The poster, used when there is no [background] or it will not load.
  final String? poster;

  /// Drawn over the scrim at full strength.
  final Widget child;

  /// The host whose URLs name their own size, and the only one [atSize]
  /// rewrites.
  static const String metahubHost = 'images.metahub.space';

  /// The size a full-screen backdrop is asked for: big enough not to be
  /// upscaled on a 1080p panel, and not the original, which for a
  /// background is close to a megabyte.
  static const String imageSize = 'medium';

  /// Black over the picture, heaviest where the header sits. The lightest
  /// stop is still most of the way to opaque: the whole point is that a
  /// white logo and a white focus ring read over *any* frame of any film,
  /// and the frame is the part nothing here gets to choose.
  static const LinearGradient scrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xE0000000), Color(0xC0000000), Color(0xA0000000)],
  );

  /// [url] asking metahub for [size] instead of whatever size it names.
  ///
  /// A metahub image URL is `/<kind>/<size>/<id>/img`, so the size is one
  /// path segment and nothing else in the URL moves. Anything that is not
  /// a metahub URL of that shape comes back unchanged: an addon that hosts
  /// its own artwork has no size to ask for, and guessing at one would
  /// turn a picture that works into a 404.
  static String? atSize(String? url, String size) {
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host != metahubHost) return url;
    final segments = uri.pathSegments;
    if (segments.length != 4 || segments[1] == size) return url;
    return uri
        .replace(pathSegments: [segments.first, size, ...segments.skip(2)])
        .toString();
  }

  @override
  Widget build(BuildContext context) {
    final urls = [?atSize(background, imageSize), ?atSize(poster, imageSize)];
    // The panel's own pixels: a backdrop is never drawn larger than the
    // screen, so decoding it larger only costs memory. `cacheWidth` counts
    // physical pixels, which is why the ratio is in here.
    final media = MediaQuery.of(context);
    final decodeWidth = (media.size.width * media.devicePixelRatio).round();
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
        _image(urls, 0, decodeWidth > 0 ? decodeWidth : null),
        const DecoratedBox(decoration: BoxDecoration(gradient: scrim)),
        child,
      ],
    );
  }

  /// The [index]th URL, falling through to the next one when it will not
  /// load and to nothing at all -- the ground below -- once they run out.
  static Widget _image(List<String> urls, int index, int? cacheWidth) =>
      index >= urls.length
      ? const SizedBox.shrink()
      : Image.network(
          urls[index],
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: cacheWidth,
          errorBuilder: (_, _, _) => _image(urls, index + 1, cacheWidth),
        );
}
