import 'package:flutter/painting.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/seek_bar.dart';

import '../../support/player_harness.dart';

/// The seek bar to a screen reader, on the player: a slider of its own
/// over the bar while the controls are up, and nothing at all while they
/// are not.
///
/// On a phone the slider merged into the screen's own node -- the whole
/// screen, the title and "Seek" run together as one label -- so a screen
/// reader took the entire screen for the seek bar, whether the controls
/// were drawn or not.
void main() {
  /// Every node in the tree that says it is a slider.
  List<SemanticsNode> sliders(WidgetTester tester) {
    final found = <SemanticsNode>[];
    bool visit(SemanticsNode node) {
      if (node.getSemanticsData().flagsCollection.isSlider) {
        found.add(node);
      }
      node.visitChildren(visit);
      return true;
    }

    for (final view in tester.binding.renderViews) {
      final root = view.owner?.semanticsOwner?.rootSemanticsNode;
      if (root != null) visit(root);
    }
    return found;
  }

  /// Where [node] is on screen, in the view's logical pixels.
  Rect globalRect(SemanticsNode node) {
    var rect = node.rect;
    for (SemanticsNode? at = node; at != null; at = at.parent) {
      final transform = at.transform;
      if (transform != null) {
        rect = MatrixUtils.transformRect(transform, rect);
      }
    }
    return rect;
  }

  Future<PlayerHarness> pumpPhone(WidgetTester tester) async {
    usePhoneViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(minutes: 96));
    harness.engine.emitPosition(const Duration(seconds: 65));
    await pumpEvents(tester);
    return harness;
  }

  /// Plays until the controls' idle timeout has run, the position moving
  /// so that nothing reads the player as stalled.
  Future<void> playPastTheTimeout(
    WidgetTester tester,
    PlayerHarness harness,
  ) async {
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    var position = const Duration(seconds: 65);
    for (
      var elapsed = Duration.zero;
      elapsed < PlayerScreen.controlsTimeout;
      elapsed += PlayerScreen.stuckInterval
    ) {
      position += PlayerScreen.stuckInterval;
      harness.engine.emitPosition(position);
      await tester.pump(PlayerScreen.stuckInterval);
    }
  }

  testWidgets('with the controls up the slider is the bar, and only the bar', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpPhone(tester);
    expect(controlsOpacity(tester), 1);

    final found = sliders(tester);
    expect(found, hasLength(1));
    final slider = found.single;
    expect(slider.label, 'Seek', reason: 'merged with what is around it');
    expect(slider.value, '1:05 of 1:36:00');
    expect(globalRect(slider), tester.getRect(find.byType(SeekBar)));
    handle.dispose();
  });

  testWidgets('with the controls hidden there is no slider, fading or gone', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final harness = await pumpPhone(tester);
    await playPastTheTimeout(tester, harness);
    // Half-way through the fade: drawn, faintly, and already hidden.
    await tester.pump(const Duration(milliseconds: 100));
    expect(controlsOpacity(tester), 0);
    expect(sliders(tester), isEmpty, reason: 'a slider over a fading bar');

    await tester.pumpAndSettle();
    expect(sliders(tester), isEmpty);
    // Up again, the slider comes back with the bar.
    await tapVideo(tester);
    expect(controlsOpacity(tester), 1);
    expect(sliders(tester), hasLength(1));
    handle.dispose();
  });
}
