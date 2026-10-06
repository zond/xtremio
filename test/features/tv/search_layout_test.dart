import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/discover/catalog_rows.dart';
import 'package:xtremio/features/search/search_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_text_entry.dart';
import 'package:xtremio/widgets/poster_tile.dart';
import 'package:xtremio/widgets/tv_text_field.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_sharing.dart';
import '../../support/fixtures.dart';
import '../../support/text_entry.dart';
import '../../support/tv.dart';

/// A Google TV: a 1920x1080 panel at a pixel ratio of 2, so the app lays
/// out on 960x540.
const Size logical = Size(960, 540);

/// The band a television may crop, top and bottom, in logical pixels.
const double band = 540 * 0.05;

/// The query the search fixture was recorded for.
const String recorded = 'night of the living dead';

/// The app on [device] with nothing searched yet.
Future<FakeCoreClient> pumpApp(
  WidgetTester tester, {
  DeviceProfile device = tv,
}) async {
  final core = FakeCoreClient(
    state: {
      CoreField.ctx: loadCtxLoggedOutFixture(),
      CoreField.board: loadBoardFixture(),
      CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
      CoreField.search: {
        'selected': null,
        'catalogs': <Object>[],
        'catalogLabels': <Object>[],
      },
    },
  );
  await tester.pumpWidget(
    XtremioApp(
      core: core,
      device: device,
      sharingActivity: FakeSharingActivity(),
    ),
  );
  await tester.pumpAndSettle();
  return core;
}

void useTv(WidgetTester tester) {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

/// From Discover's first tile, where the app starts, to the Search tab,
/// the remote left on the rail's Search.
Future<void> openSearch(WidgetTester tester) async {
  await press(tester, LogicalKeyboardKey.arrowLeft);
  expect(focusIn<NavigationRail>(), isTrue);
  // Left lands on whichever destination is level with the tile: up to the
  // first, Discover, then down one.
  for (var i = 0; i < 4; i++) {
    await press(tester, LogicalKeyboardKey.arrowUp);
  }
  await press(tester, LogicalKeyboardKey.arrowDown);
  await press(tester, LogicalKeyboardKey.select);
  expect(find.byType(SearchScreen), findsOneWidget);
}

/// The Searches dispatched so far, by query.
List<String> searches(FakeCoreClient core) => [
  for (final action in core.dispatched)
    if (action.field == CoreField.search && action.action['action'] == 'Load')
      ((action.action['args']['args'] as Map<String, dynamic>)['extra']
                  as List<dynamic>)
              .cast<List<dynamic>>()
              .single[1]
          as String,
];

/// Types [query] on the platform's screen, from the focused field, and
/// lets the recorded answer come back.
Future<void> searchFor(
  WidgetTester tester,
  FakeCoreClient core,
  String query,
) async {
  answerTextEntry(query);
  await tester.sendKeyEvent(LogicalKeyboardKey.select);
  await settleTextEntry(tester);
  core.setState(CoreField.search, loadSearchFixture());
  await tester.pumpAndSettle();
}

void main() {
  group('on a television', () {
    testWidgets('the field is the top of the screen, inside the band, under '
        'no title', (tester) async {
      useTv(tester);
      await pumpApp(tester);
      await openSearch(tester);

      expect(
        find.descendant(
          of: find.byType(SearchScreen),
          matching: find.byType(AppBar),
        ),
        findsNothing,
      );
      final field = tester.getRect(find.byType(TvTextField));
      expect(field.top, band, reason: 'at the edge of the band, not in it');
      expect(
        tester.widget<TvTextField>(find.byType(TvTextField)).decoration.border,
        isA<OutlineInputBorder>(),
        reason: 'out of the app bar, a box of its own says it is a field',
      );
      // Before anything is searched, the phone's hint, under the field.
      final hint = tester.getRect(
        find.text('Search movies, series and channels'),
      );
      expect(hint.top, greaterThan(field.bottom));
      expect(hint.bottom, lessThan(logical.height - band));
    });

    testWidgets('the microphone is right of the field, and what it hears '
        'is searched for', (tester) async {
      useTv(tester);
      final core = await pumpApp(tester);
      await openSearch(tester);
      final field = tester.getRect(find.byType(InputDecorator));
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'TvTextField voice',
      );
      final mic = tester.getRect(find.byKey(const Key('tv-text-field-voice')));
      expect(mic.top, greaterThanOrEqualTo(field.top));
      expect(mic.bottom, lessThanOrEqualTo(field.bottom));
      expect(mic.right, field.right);

      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DeviceProfile.channel,
        (call) async {
          calls.add(call);
          return switch (call.method) {
            TvTextEntry.canRecognizeSpeechMethod => true,
            TvTextEntry.recognizeSpeechMethod => recorded,
            _ => null,
          };
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DeviceProfile.channel,
          null,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await settleTextEntry(tester);
      expect(calls.last.method, TvTextEntry.recognizeSpeechMethod);
      expect(
        tester.widget<TvTextField>(find.byType(TvTextField)).controller.text,
        recorded,
      );
      expect(searches(core), [recorded]);
    });

    testWidgets('a hardware keyboard types into the field, and the search '
        'follows the pause in typing', (tester) async {
      useTv(tester);
      final core = await pumpApp(tester);
      await openSearch(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusIn<TvTextField>(), isTrue);
      // No screen opens for a keyboard's typing.
      final calls = answerTextEntry('never asked for');

      for (final key in [
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.keyI,
        LogicalKeyboardKey.keyX,
        LogicalKeyboardKey.backspace,
        LogicalKeyboardKey.keyG,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pump(SearchScreen.debounce ~/ 2);
      }
      expect(
        tester.widget<TvTextField>(find.byType(TvTextField)).controller.text,
        'nig',
      );
      expect(searches(core), isEmpty, reason: 'still typing');
      expect(calls, isEmpty);

      await tester.pump(SearchScreen.debounce);
      expect(searches(core), ['nig']);
      expect(focusIn<TvTextField>(), isTrue);

      // A shortcut is not typing, and neither is a control character.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab, character: '\t');
      await tester.pump(SearchScreen.debounce);
      expect(
        tester.widget<TvTextField>(find.byType(TvTextField)).controller.text,
        'nig',
      );
      expect(searches(core), ['nig']);
    });

    testWidgets('the results are rows of the television\'s posters, two of '
        'them whole at rest', (tester) async {
      useTv(tester);
      final core = await pumpApp(tester);
      await openSearch(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await searchFor(tester, core, recorded);
      expect(searches(core), [recorded]);

      expect(find.byType(PosterRows), findsOneWidget);
      expect(find.byType(SliverGrid), findsNothing);
      final field = tester.getRect(find.byType(TvTextField));
      final safeBottom = logical.height - band;
      final first = tester.getRect(
        find.textContaining('Movies · Cinemeta', findRichText: true).first,
      );
      final second = tester.getRect(
        find.textContaining('Series · Cinemeta', findRichText: true).first,
      );
      expect(first.top, greaterThan(field.bottom));
      expect(second.top, greaterThan(first.bottom));
      final tiles = tester.getRect(find.byType(PosterTile).first);
      expect(tiles.top, greaterThan(first.bottom));
      expect(tiles.bottom, lessThanOrEqualTo(second.top));
      final last = find.descendant(
        of: find.byType(SliverFixedExtentList),
        matching: find.byType(PosterTile),
      );
      // The second row's one tile, Cinemeta's only series hit.
      final secondRowTile = tester
          .getRect(last.evaluate().length > 1 ? last.at(1) : last)
          .bottom;
      expect(secondRowTile, lessThanOrEqualTo(safeBottom));
      expect(
        tester.getSize(find.byType(PosterTile).first).width,
        PosterTile.tvImageWidth,
      );
      // The first row runs on into the band at the right, as Discover's do.
      expect(
        tester.getRect(find.byType(PosterTile).at(6)).right,
        greaterThan(logical.width * 0.95),
      );
    });

    testWidgets('the remote walks between the field, the rows and the rail', (
      tester,
    ) async {
      useTv(tester);
      final core = await pumpApp(tester);
      await openSearch(tester);
      expect(
        focusIn<NavigationRail>(),
        isTrue,
        reason: 'opening the tab leaves the remote on the rail, as every tab',
      );
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusIn<TvTextField>(), isTrue);
      await searchFor(tester, core, recorded);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<PosterTile>(), isTrue, reason: 'down: the first row');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<TvTextField>(), isTrue, reason: 'up: the field');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusIn<NavigationRail>(), isTrue, reason: 'left: the rail');

      // Back down into the row, and along it to its first tile: one more
      // left is the rail.
      await press(tester, LogicalKeyboardKey.arrowRight);
      if (!focusIn<PosterTile>()) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusIn<PosterTile>(), isTrue);
      for (var i = 0; i < 40 && focusIn<PosterTile>(); i++) {
        await press(tester, LogicalKeyboardKey.arrowLeft);
      }
      expect(
        focusIn<NavigationRail>(),
        isTrue,
        reason: 'left from a row\'s first tile: the rail',
      );
    });

    testWidgets('Back on the keyboard\'s screen leaves the field and the tab '
        'as they were', (tester) async {
      useTv(tester);
      final core = await pumpApp(tester);
      await openSearch(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await searchFor(tester, core, recorded);
      final before = core.dispatched.length;

      // The screen answers null when Back closes it.
      final calls = answerTextEntry(null);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await settleTextEntry(tester);
      await tester.pump(SearchScreen.debounce);

      expect(calls.single.method, 'editText');
      expect(find.byType(SearchScreen), findsOneWidget);
      expect(focusIn<TvTextField>(), isTrue);
      expect(
        tester.widget<TvTextField>(find.byType(TvTextField)).controller.text,
        recorded,
      );
      expect(core.dispatched.length, before);
    });
  });

  testWidgets('a phone keeps the field in its app bar and the results as '
      'grids', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = await pumpApp(tester, device: DeviceProfile.fallback);
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(TextField),
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), recorded);
    await tester.pump(SearchScreen.debounce);
    core.setState(CoreField.search, loadSearchFixture());
    await tester.pumpAndSettle();
    expect(searches(core), [recorded]);
    expect(find.byType(SliverGrid), findsWidgets);
    expect(find.byType(PosterRows), findsNothing);
  });
}
