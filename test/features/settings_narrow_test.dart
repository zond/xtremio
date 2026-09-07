import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/settings/core_settings.dart';

import '../support/fixtures.dart';

/// The settings controls at the widths phones really are.
///
/// Every other test of this screen mounts it 900 dp wide, which is the one
/// width the menu tiles were ever laid out at. Their menu was the tile's
/// `trailing`; a [DropdownButton] is as wide as its widest item, and
/// `ListTile` lets `trailing` take the whole content width -- so on a phone
/// the menu took the row, the title and the subtitle were laid out in what
/// was left of it (nothing), and below about 436 dp a debug build threw
/// "Trailing widget consumes the entire tile width" and took the screen
/// down with a cascade of `hasSize` failures. Real phones are 360-430 dp.
///
/// So these run at three phone widths and check the property that was
/// missing rather than the tile that was missing it: **every word is laid
/// out in a box wide enough to hold it, and inside the screen.** A control
/// that claims a row it cannot have fails that whichever tile it is on.
void main() {
  /// Every word drawn right now sits in a box that fits it, on screen.
  ///
  /// The check is on the box the text was *given*: a zero-width box is the
  /// shape the collapse took, since `ListTile` hands its title whatever the
  /// trailing left over, clamped at zero, and the text then wraps a letter
  /// to a line inside it. One word longer than any box on a narrow screen
  /// could be -- an email address, a server URL -- is the text's own
  /// business and `Text` clips it, so the width check is on what can be
  /// broken across lines and every box is checked for being there at all.
  void expectTextFits(WidgetTester tester, double width, String where) {
    for (final element in find.byType(Text).evaluate()) {
      final text = (element.widget as Text).data;
      if (text == null || text.trim().isEmpty) continue;
      final rect = tester.getRect(find.byElementPredicate((e) => e == element));
      expect(
        rect.width,
        greaterThan(0),
        reason: '$where: "$text" was laid out at zero width',
      );
      if (text.trim().contains(RegExp(r'\s'))) {
        final render = element.renderObject! as RenderParagraph;
        final longestWord = render.getMinIntrinsicWidth(double.infinity);
        expect(
          rect.width + 0.5,
          greaterThanOrEqualTo(longestWord),
          reason:
              '$where: "$text" was given ${rect.width} dp, and its longest '
              'word needs $longestWord',
        );
      }
      expect(
        rect.left,
        greaterThanOrEqualTo(-0.5),
        reason: '$where: "$text" starts off the left edge at ${rect.left}',
      );
      expect(
        rect.right,
        lessThanOrEqualTo(width + 0.5),
        reason: '$where: "$text" runs past the right edge to ${rect.right}',
      );
    }
  }

  /// The sections built out of menu tiles, one under the other at [width],
  /// with the longest label there is picked in the one that had it.
  Future<void> pumpMenuTiles(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = AppPrefs.inMemory();
    addTearDown(prefs.dispose);
    await prefs.setBufferAhead(BufferAhead.wholeFile);
    final settings = ProfileSettings(
      loadCtxLoggedOutFixture()['profile']['settings'] as Map<String, dynamic>,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              BufferAheadSection(prefs: prefs),
              PlayerSettingsSection(settings: settings, onSetting: (_, _) {}),
              SubtitlesSettingsSection(
                settings: settings,
                onSetting: (_, _) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 360.0, 411.0]) {
    testWidgets('every menu tile fits at $width dp', (tester) async {
      await pumpMenuTiles(tester, width);
      expectTextFits(tester, width, 'the menu tiles at $width dp');
      // Whole, not clipped to the widest thing that happened to fit: this
      // is the label that used to take the row, and the language lists
      // are the ones that will grow.
      expect(find.text(BufferAhead.wholeFile.label), findsOneWidget);
      expect(find.text('English'), findsNWidgets(2));
    });
  }

  testWidgets('a menu tile still picks a value at 320 dp', (tester) async {
    // The point of the row is that it can be used, not that it renders:
    // the menu opens over a 320 dp screen and the pick lands.
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = AppPrefs.inMemory();
    addTearDown(prefs.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: prefs,
            builder: (context, _) =>
                ListView(children: [BufferAheadSection(prefs: prefs)]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(prefs.bufferAhead, BufferAhead.normal);
    await tester.tap(find.byKey(settingKey(AppPrefs.bufferAheadKey)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(BufferAhead.wholeFile.label).last);
    await tester.pumpAndSettle();

    expect(prefs.bufferAhead, BufferAhead.wholeFile);
    // The whole of the longest label there is, on the width whose row it
    // used to take all of.
    expect(find.text(BufferAhead.wholeFile.label), findsOneWidget);
  });
}
