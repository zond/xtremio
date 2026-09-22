/// Draws the proposed details ladder at 1280x720 and writes it out, so the
/// density can be looked at rather than imagined. Not a test of the app:
/// nothing here asserts behaviour, and it should go once the layout is
/// settled.
///
///   flutter test --update-goldens test/prototypes/details_density_test.dart
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'details_density.dart';

/// A widget test draws text as blank boxes unless a font with glyphs in it
/// is loaded, and a drawing made to be looked at needs words.
Future<void> useARealFont() async {
  const candidates = [
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf',
    '/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf',
  ];
  final path = candidates.firstWhere(
    (p) => File(p).existsSync(),
    orElse: () => '',
  );
  if (path.isEmpty) return;
  final bytes = await File(path).readAsBytes();
  for (final family in ['proto', 'Roboto', 'sans-serif']) {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
}

void main() {
  setUpAll(useARealFont);
  Future<void> draw(WidgetTester tester, String name, Widget child) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1280, 720)),
        child: child,
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(DetailsPrototype),
      matchesGoldenFile('$name.png'),
    );
  }

  testWidgets('arriving at something you were watching', (tester) async {
    // Only the rung that matters is open: one press plays it.
    await draw(
      tester,
      'details_1_arrival',
      const DetailsPrototype(
        focused: 0,
        rungs: [
          Rung('Continue watching', open: true, child: ContinueCard()),
          Rung('Episodes', summary: 'Season 1 · 13'),
          Rung('Sources', summary: '58 from 4 add-ons'),
          Rung('More like this', summary: '7 films'),
        ],
      ),
    );
  });

  testWidgets('sources opened, resolutions as pills', (tester) async {
    await draw(
      tester,
      'details_2_sources',
      const DetailsPrototype(
        focused: 2,
        rungs: [
          Rung('Continue watching', summary: '48 min left'),
          Rung('Episodes', summary: 'Season 1 · 13'),
          Rung(
            'Sources',
            summary: '58 from 4 add-ons',
            open: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ResolutionPills(chosen: 1),
                SizedBox(height: 10),
                SourceCards(highlight: 0),
              ],
            ),
          ),
          Rung('More like this', summary: '7 films'),
        ],
      ),
    );
  });

  testWidgets('the recommendations row at the bottom of the ladder', (
    tester,
  ) async {
    await draw(
      tester,
      'details_3_recommendations',
      const DetailsPrototype(
        focused: 3,
        rungs: [
          Rung('Continue watching', summary: '48 min left'),
          Rung('Episodes', summary: 'Season 1 · 13'),
          Rung('Sources', summary: '58 from 4 add-ons'),
          Rung(
            'More like this',
            summary: '7 films',
            open: true,
            child: RecommendationRow(focused: 1),
          ),
        ],
      ),
    );
  });

  testWidgets('everything open at once, which is what we are avoiding', (
    tester,
  ) async {
    await draw(
      tester,
      'details_4_everything',
      const DetailsPrototype(
        focused: 2,
        rungs: [
          Rung(
            'Continue watching',
            open: true,
            child: ContinueCard(focused: false),
          ),
          Rung(
            'Sources',
            summary: '58 from 4 add-ons',
            open: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ResolutionPills(chosen: 1),
                SizedBox(height: 10),
                SourceCards(highlight: 0),
              ],
            ),
          ),
          Rung(
            'More like this',
            summary: '7 films',
            open: true,
            child: RecommendationRow(),
          ),
        ],
      ),
    );
  });
}
