import 'package:flutter/material.dart';

import 'device_profile.dart';

/// The ten-foot dimensions: what changes about sizes, spacing and text when
/// [DeviceProfile.isTv] is true.
///
/// A television is read from a sofa, not from arm's length, and pointed at
/// with a D-pad rather than a finger, so everything it draws is a little
/// bigger and a little further apart than the phone/desktop layout: the
/// theme is one density step roomier than the standard one, every button
/// keeps a [minTarget] box whatever the icon inside it measures, text is
/// scaled by [textScale], and the shell holds [overscan] of the panel free
/// at every edge because a television may not show it.
///
/// Nothing here reads the device itself; `XtremioApp` applies [theme] and
/// [TvMediaQuery] when the [DeviceScope] says television, so every other
/// screen simply inherits the theme, the text scale and the band.
abstract final class TvDensity {
  /// One step *roomier* than [VisualDensity.standard], for the ten-foot
  /// distance.
  ///
  /// Deliberately not `VisualDensity.comfortable`: in Flutter that constant
  /// is `(-1, -1)`, a step **denser** than standard (`compact` is `(-2,
  /// -2)`), so it would shrink the very targets a remote has the hardest
  /// time hitting. Positive values grow them instead.
  static const VisualDensity visualDensity = VisualDensity(
    horizontal: 1,
    vertical: 1,
  );

  /// Every tappable box is at least this tall and wide, the Material
  /// minimum touch target, which is also about as small as a focus ring may
  /// get before it stops reading as one across a room.
  static const double minTarget = 48;

  /// Text is this much larger than the same screen on a phone.
  static const double textScale = 1.15;

  /// The fraction of each edge a television may crop (overscan) or bend out
  /// of sight, kept clear of anything the app draws.
  static const double overscan = 0.05;

  /// [base] with the television's density and minimum target size.
  static ThemeData theme(ThemeData base) => base.copyWith(
    visualDensity: visualDensity,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size.square(minTarget)),
      ),
    ),
  );

  /// [base] — whatever the platform's own accessibility setting scales text
  /// by — with the television's [textScale] on top, so a viewer who asked
  /// for larger text still gets it.
  static TextScaler textScaler(TextScaler base) => _TvTextScaler(base);

  /// [overscan] of the given screen, as padding.
  static EdgeInsets overscanPadding(Size screen) => EdgeInsets.symmetric(
    horizontal: screen.width * overscan,
    vertical: screen.height * overscan,
  );
}

/// [TvDensity.textScale] applied on top of another scaler.
@immutable
class _TvTextScaler extends TextScaler {
  const _TvTextScaler(this.base);

  final TextScaler base;

  @override
  double scale(double fontSize) => base.scale(fontSize * TvDensity.textScale);

  @override
  double get textScaleFactor => scale(1);

  @override
  bool operator ==(Object other) =>
      other is _TvTextScaler && other.base == base;

  @override
  int get hashCode => Object.hash(_TvTextScaler, base);

  @override
  String toString() => 'TvTextScaler($base × ${TvDensity.textScale})';
}

/// The television's text scale and overscan band, as the `MediaQuery` every
/// route sees.
///
/// `XtremioApp` installs one of these through `MaterialApp.builder`, which
/// wraps the navigator rather than the shell, so the screens pushed over the
/// shell -- Details, the player -- get the same band the shell does. The
/// band arrives as [MediaQueryData.padding] rather than as a `Padding`
/// widget on purpose: a screen decides for itself which parts of it must
/// stay on the panel (its chrome, through [TvSafeArea] or `SafeArea`) and
/// which are meant to bleed off it (the video).
class TvMediaQuery extends StatelessWidget {
  const TvMediaQuery({super.key, required this.child});

  final Widget child;

  /// This widget as a `MaterialApp.builder`.
  static Widget builder(BuildContext context, Widget? child) =>
      TvMediaQuery(child: child ?? const SizedBox.shrink());

  @override
  Widget build(BuildContext context) {
    final data = MediaQuery.of(context);
    final overscan = TvDensity.overscanPadding(data.size);
    return MediaQuery(
      data: data.copyWith(
        textScaler: TvDensity.textScaler(data.textScaler),
        padding: data.padding + overscan,
        viewPadding: data.viewPadding + overscan,
      ),
      child: child,
    );
  }
}

/// A [SafeArea] on a television, and nothing at all anywhere else.
///
/// What a screen wraps in one of these is what a set that overscans must
/// still show: an app bar with the way back in its corner, a row of
/// controls. Off a television it is not a `SafeArea` at all, so a phone's
/// notch keeps being handled exactly where it always was.
///
/// The band is filled with the scaffold's own colour, so a route that has
/// stepped out of it does not leave the route underneath showing through.
class TvSafeArea extends StatelessWidget {
  const TvSafeArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DeviceScope.isTv(context)
      ? ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: SafeArea(child: child),
        )
      : child;
}
