import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/library_item_tile.dart';

const tv = DeviceProfile(isTv: true, hasTouch: false);

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
  testWidgets('the focused tile lifts its episode line to full strength', (
    tester,
  ) async {
    // A muted caption under a poster is the second thing a projector in a
    // lit room loses, after the ring itself.
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    final scheme = Theme.of(tester.element(find.byType(LibraryItemTile)))
        .colorScheme;
    expect(episodeColour(tester), scheme.onSurfaceVariant);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(episodeColour(tester), scheme.onSurface);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(episodeColour(tester), scheme.onSurfaceVariant);
  });

  testWidgets('off a television the line is the muted one it always was', (
    tester,
  ) async {
    // No tile focus above it there at all, which is not the same as an
    // unfocused one: a phone's caption is the only caption.
    await tester.pumpWidget(harness(device: DeviceProfile.fallback));
    await tester.pumpAndSettle();
    final scheme = Theme.of(tester.element(find.byType(LibraryItemTile)))
        .colorScheme;
    expect(episodeColour(tester), scheme.onSurfaceVariant);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(episodeColour(tester), scheme.onSurfaceVariant);
  });
}
