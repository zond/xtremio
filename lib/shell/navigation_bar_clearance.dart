import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Keeps every screen above Android's navigation bar.
///
/// Android draws the app behind its navigation bar, and nothing turns that
/// off any more. The bar with three buttons is about 48 dp tall and only
/// half see-through, so the last row of a title's page, the end of a list or
/// a button at the bottom of a sheet sat under it. Gesture navigation hides
/// the same mistake behind a thin handle.
///
/// The root screen's tab bar already kept clear, but nothing else did. One
/// margin here covers every screen, dialog and sheet, including ones not
/// written yet. A screen fixed one by one would be missed again by the next
/// screen.
///
/// Only the bottom. The status bar is the app bars' to clear, and they do.
/// A side margin would also catch a camera cutout, which is not in the way
/// of anything on a phone held upright.
///
/// The player hides the bars while it plays, and a hidden bar takes no
/// room, so the picture still reaches the edge.
///
/// The strip under the bar is filled with the screen's background, so the
/// bar's own shading has something to sit on. A television is left alone:
/// it has no navigation bar, and its overscan margin comes down the same
/// way and is handled where each screen is laid out (`TvSafeArea`).
abstract final class NavigationBarClearance {
  /// For [MaterialApp.builder].
  static Widget builder(BuildContext context, Widget? child) {
    final content = child ?? const SizedBox.shrink();
    if (defaultTargetPlatform != TargetPlatform.android) return content;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(top: false, left: false, right: false, child: content),
    );
  }
}
