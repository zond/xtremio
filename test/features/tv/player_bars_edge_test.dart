import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_controls.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// **The player's bars shade the film out to the edge of the screen, and
/// keep their buttons inside the overscan band.**
///
/// A television keeps [TvDensity.overscan] of every edge clear. The bars'
/// gradients run from black at the screen's edge to clear, so the band
/// between the buttons and the edge is shaded like the rest of the bar. A
/// gradient drawn inside the band would stop short of the edge, and the film
/// would show bright again below the dark.
void main() {
  testWidgets('the bars reach the edges, and their buttons stay inside the '
      'band', (tester) async {
    useScreen(tester, tvSize);
    final harness = PlayerHarness(device: tv);
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(minutes: 45));
    harness.engine.emitPosition(const Duration(seconds: 65));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    expect(controlsOpacity(tester), 1);

    final band = TvDensity.overscanPadding(tvSize);
    Rect shade(Type bar) => tester.getRect(
      find
          .descendant(of: find.byType(bar), matching: find.byType(DecoratedBox))
          .first,
    );

    final top = shade(PlayerTopBar);
    expect(top.top, 0);
    expect(top.left, 0);
    expect(top.right, tvSize.width);
    final bottom = shade(PlayerBottomBar);
    expect(bottom.bottom, tvSize.height);
    expect(bottom.left, 0);
    expect(bottom.right, tvSize.width);

    final back = tester.getRect(find.byTooltip('Back'));
    expect(back.top, greaterThanOrEqualTo(band.top));
    expect(back.left, greaterThanOrEqualTo(band.left));
    final play = tester.getRect(find.byTooltip('Pause (Space)'));
    expect(play.bottom, lessThanOrEqualTo(tvSize.height - band.bottom));
    expect(play.left, greaterThanOrEqualTo(band.left));
  });
}
