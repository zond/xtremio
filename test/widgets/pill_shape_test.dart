/// Every pill is one shape: the selected fill, the ink a press, a hover or
/// a focus spreads, and the ring a television draws round it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/features/details/details_header.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/filter_controls.dart';
import 'package:xtremio/widgets/focusable_tile.dart';

import '../support/tv.dart' show tv;

const DeviceProfile phone = DeviceProfile(isTv: false, hasTouch: true);

Widget harness(DeviceProfile device, Widget child) => DeviceScope(
  profile: device,
  child: MaterialApp(
    theme: XtremioApp.themeFor(isTv: device.isTv),
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

/// The chip's body: the [Material] its fill is painted in.
Material bodyOf(WidgetTester tester, Finder chip) => tester.widget<Material>(
  find.descendant(of: chip, matching: find.byType(Material)).first,
);

Finder bodyFinder(Finder chip) =>
    find.descendant(of: chip, matching: find.byType(Material)).first;

void main() {
  for (final device in [phone, tv]) {
    final name = device.isTv ? 'television' : 'phone';

    testWidgets('on a $name every kind of chip is a stadium, ink and all', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          device,
          Wrap(
            children: [
              ChoiceChip(
                label: const Text('choice'),
                selected: true,
                onSelected: (_) {},
              ),
              FilterChip(
                label: const Text('filter'),
                selected: true,
                onSelected: (_) {},
              ),
              ActionChip(label: const Text('action'), onPressed: () {}),
            ],
          ),
        ),
      );
      for (final type in [ChoiceChip, FilterChip, ActionChip]) {
        final chip = find.byType(type);
        expect(
          bodyOf(tester, chip).shape,
          isA<StadiumBorder>(),
          reason: '$type fills a shape that is not the pill',
        );
        final ink = tester.widget<InkWell>(
          find.descendant(of: chip, matching: find.byType(InkWell)),
        );
        expect(
          ink.customBorder,
          isA<StadiumBorder>(),
          reason: "$type's press, hover and focus ink is not the pill",
        );
      }
    });

    testWidgets('on a $name a season pill fills its slot', (tester) async {
      await tester.pumpWidget(
        harness(
          device,
          SeasonSelector(
            seasons: const [1, 2, 3],
            selected: 2,
            onChanged: (_) {},
          ),
        ),
      );
      for (final season in ['1', '2', '3']) {
        final chip = find.widgetWithText(ChoiceChip, season);
        final body = tester.getRect(bodyFinder(chip));
        // What the slot is: the box the row gave the pill, which is what a
        // television's ring is drawn round.
        final slot = tester.getRect(
          find.ancestor(of: chip, matching: find.byType(ConstrainedBox)).last,
        );
        expect(
          body.width,
          slot.width,
          reason: 'season $season is a small pill in a wide slot',
        );
        expect(body.left, slot.left);
      }
    });
  }

  testWidgets('a focused season pill wears a ring of its own shape', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        tv,
        SeasonSelector(
          seasons: const [1, 2, 3],
          selected: 2,
          onChanged: (_) {},
        ),
      ),
    );
    final chip = find.widgetWithText(ChoiceChip, '2');
    Focus.of(
      tester.element(find.descendant(of: chip, matching: find.text('2'))),
    ).requestFocus();
    await tester.pumpAndSettle();

    final ring = find.ancestor(of: chip, matching: find.byType(FocusRing));
    expect(tester.widget<FocusRing>(ring).focused, isTrue);
    final ringRect = tester.getRect(ring);
    final body = tester.getRect(bodyFinder(chip));
    // The ring and the pill are both stadiums: end to end the same width,
    // the ring no further from the pill at the ends than above and below.
    expect(ringRect.width, body.width);
    expect(
      tester.widget<FocusRing>(ring).borderRadius.topLeft.x,
      greaterThanOrEqualTo(ringRect.height / 2),
    );
    expect(bodyOf(tester, chip).shape, isA<StadiumBorder>());
  });

  testWidgets('a focused filter chip on a television: ring and pill agree', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        tv,
        FilterChips<int>(
          options: const [
            FilterOption(label: 'All', selected: true, request: 0),
            FilterOption(label: 'Movies', selected: false, request: 1),
          ],
          onSelect: (_) {},
        ),
      ),
    );
    final chip = find.widgetWithText(ChoiceChip, 'Movies');
    Focus.of(
      tester.element(find.descendant(of: chip, matching: find.text('Movies'))),
    ).requestFocus();
    await tester.pumpAndSettle();
    final ring = find.ancestor(of: chip, matching: find.byType(FocusRing));
    expect(tester.widget<FocusRing>(ring).focused, isTrue);
    expect(
      tester.widget<FocusRing>(ring).borderRadius.topLeft.x,
      greaterThanOrEqualTo(tester.getRect(ring).height / 2),
    );
    expect(bodyOf(tester, chip).shape, isA<StadiumBorder>());
  });
}
