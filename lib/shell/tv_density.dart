import 'package:flutter/material.dart';

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
/// Nothing here reads the device itself; `XtremioApp` and `RootShell` apply
/// it when the [DeviceScope] says television, so every other screen simply
/// inherits the theme and the text scale.
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
