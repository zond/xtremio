import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/focusable_tile.dart';
import 'package:xtremio/widgets/library_item_tile.dart';
import 'package:xtremio/widgets/poster_tile.dart';

import '../support/tv.dart';

/// A series with an episode in progress, so the tile has a second line.
final lanterns = LibraryItemView({
  '_id': 'tt0903747',
  'type': 'series',
  'name': 'Lanterns',
  'state': {'video_id': 'tt0903747:2:3', 'timeOffset': 10, 'duration': 100},
});

Widget harness({DeviceProfile device = tv}) => DeviceScope(
  profile: device,
  child: MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 160,
        height: 260,
        child: LibraryItemTile(item: lanterns, onTap: () {}),
      ),
    ),
  ),
);

/// The colour the "S2E3" line is drawn in.
Color? episodeColour(WidgetTester tester) =>
    tester.widget<Text>(find.text('S2E3')).style?.color;

void main() {
  testWidgets('the caption clears the bold focus ring, all of it', (
    tester,
  ) async {
    for (final device in [tv, DeviceProfile.fallback]) {
      await tester.pumpWidget(harness(device: device));
      final tile = tester.getRect(find.byType(LibraryItemTile));
      final name = tester.getRect(find.text('Lanterns'));
      expect(name.left - tile.left, greaterThanOrEqualTo(FocusRing.boldWidth));
      expect(
        tile.right - name.right,
        greaterThanOrEqualTo(FocusRing.boldWidth),
      );
      // The caption's last line, which the ring runs under.
      final last = device.isTv ? name : tester.getRect(find.text('S2E3'));
      expect(
        tile.bottom - last.bottom,
        greaterThanOrEqualTo(FocusRing.boldWidth),
        reason: '$device',
      );
    }
  });

  testWidgets('on a television the caption is the name alone, and the '
      'episode is a badge on the poster, above the progress bar', (
    tester,
  ) async {
    await tester.pumpWidget(harness());

    final name = tester.widget<Text>(find.text('Lanterns'));
    expect(name.maxLines, 1);
    expect(name.softWrap, isFalse);
    expect(name.overflow, TextOverflow.ellipsis);
    final badge = find.byKey(const Key('episode-badge'));
    expect(badge, findsOneWidget);
    expect(
      find.descendant(of: badge, matching: find.text('S2E3')),
      findsOneWidget,
      reason: 'the episode is in the badge and nowhere else',
    );
    expect(find.text('S2E3'), findsOneWidget);

    final poster = tester.getRect(find.byType(PosterImage));
    final bar = tester.getRect(find.byType(LinearProgressIndicator));
    final at = tester.getRect(badge);
    expect(poster.contains(at.topLeft), isTrue);
    expect(poster.contains(at.bottomRight), isTrue);
    expect(at.bottom, lessThanOrEqualTo(bar.top), reason: 'above the bar');
  });

  testWidgets('off a television the episode is the caption\'s second, muted '
      'line, and there is no badge', (tester) async {
    // No tile focus above it there at all, which is not the same as an
    // unfocused one: a phone's caption is the only caption.
    await tester.pumpWidget(harness(device: DeviceProfile.fallback));
    await tester.pumpAndSettle();
    final scheme = Theme.of(tester.element(find.byType(LibraryItemTile)))
        .colorScheme;
    expect(episodeColour(tester), scheme.onSurfaceVariant);
    expect(find.byKey(const Key('episode-badge')), findsNothing);
    expect(
      tester.getRect(find.text('S2E3')).top,
      greaterThanOrEqualTo(tester.getRect(find.text('Lanterns')).bottom),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(episodeColour(tester), scheme.onSurfaceVariant);
  });
}
