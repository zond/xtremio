import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/board/board_screen.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/player/player_controls.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';
import 'package:xtremio/shell/tv_density.dart';
import 'package:xtremio/widgets/poster_tile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// A core whose board plans no catalogs, so the shell settles instead of
/// spinning forever.
FakeCoreClient fakeCore() => FakeCoreClient(
  state: {
    CoreField.board: {
      'selected': {'type': null, 'extra': <Object>[]},
      'catalogs': <Object>[],
      'catalogLabels': <Object>[],
    },
  },
);

/// The app on [device], mounted and settled.
Future<BuildContext> pumpApp(
  WidgetTester tester, {
  required DeviceProfile device,
}) async {
  await tester.pumpWidget(XtremioApp(core: fakeCore(), device: device));
  await tester.pumpAndSettle();
  return tester.element(find.byType(RootShell));
}

/// The Details screen of the recorded movie, as a pushed route would see
/// it -- `TvMediaQuery` above it, exactly as `XtremioApp` installs it.
Future<void> pumpDetails(
  WidgetTester tester, {
  required DeviceProfile device,
}) async {
  useScreen(tester, tvSize);
  await tester.pumpWidget(
    DeviceScope(
      profile: device,
      child: CoreScope(
        client: FakeCoreClient(
          state: {CoreField.metaDetails: loadMetaDetailsFixture()},
        ),
        child: MaterialApp(
          builder: device.isTv ? TvMediaQuery.builder : null,
          home: const MetaDetailsScreen(type: 'movie', id: 'tt0063350'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The Board alone, over the recorded catalogs, on [device].
Future<void> pumpBoard(
  WidgetTester tester, {
  required DeviceProfile device,
}) async {
  useScreen(tester, tvSize);
  await tester.pumpWidget(
    DeviceScope(
      profile: device,
      child: CoreScope(
        client: FakeCoreClient(
          state: {
            CoreField.board: loadBoardFixture(),
            CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
          },
        ),
        child: const MaterialApp(home: BoardScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the ten-foot theme', () {
    testWidgets('a television gets the roomier density and padded targets', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final theme = Theme.of(await pumpApp(tester, device: tv));

      expect(theme.visualDensity, TvDensity.visualDensity);
      expect(theme.materialTapTargetSize, MaterialTapTargetSize.padded);
      expect(
        theme.iconButtonTheme.style?.minimumSize?.resolve({}),
        const Size.square(TvDensity.minTarget),
      );
    });

    testWidgets('a phone keeps the density it always had', (tester) async {
      final theme = Theme.of(
        await pumpApp(tester, device: DeviceProfile.fallback),
      );

      expect(theme.visualDensity, isNot(TvDensity.visualDensity));
      expect(theme.iconButtonTheme.style, isNull);
    });

    testWidgets('the theme holds a button open to 48 dp where the platform '
        'would shrink it', (tester) async {
      // A desktop's own density is compact, which takes an icon button
      // below the minimum target; the television theme puts it back.
      final desktop = ThemeData(platform: TargetPlatform.linux);
      Widget app(ThemeData theme) => MaterialApp(
        key: ValueKey(theme.visualDensity),
        theme: theme,
        home: Scaffold(
          body: Center(
            child: IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
          ),
        ),
      );

      await tester.pumpWidget(app(desktop));
      expect(
        tester.getSize(find.byType(IconButton)).width,
        lessThan(TvDensity.minTarget),
      );

      await tester.pumpWidget(app(TvDensity.theme(desktop)));
      final size = tester.getSize(find.byType(IconButton));
      expect(size.width, greaterThanOrEqualTo(TvDensity.minTarget));
      expect(size.height, greaterThanOrEqualTo(TvDensity.minTarget));
    });
  });

  group('overscan', () {
    testWidgets('a television holds every edge of the shell clear', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      await pumpApp(tester, device: tv);

      // The rail is the leftmost, topmost thing the shell draws, so where
      // it starts is the band the panel may eat.
      expect(
        tester.getTopLeft(find.byType(NavigationRail)),
        Offset(tvSize.width * 0.05, tvSize.height * 0.05),
      );
      expect(find.byKey(RootShell.overscanKey), findsOneWidget);
    });

    testWidgets('a desktop window uses every pixel it has', (tester) async {
      useScreen(tester, tvSize);
      await pumpApp(tester, device: DeviceProfile.fallback);

      expect(tester.getTopLeft(find.byType(NavigationRail)), Offset.zero);
      expect(find.byKey(RootShell.overscanKey), findsNothing);
    });

    testWidgets('the band reaches the routes pushed over the shell', (
      tester,
    ) async {
      // The shell is not the only thing a viewer looks at: Details and the
      // player are pushed on top of it, and a set crops their corners just
      // the same. The band therefore travels as `MediaQuery` padding from
      // above the navigator, not as a `Padding` inside the shell.
      useScreen(tester, tvSize);
      final shell = await pumpApp(tester, device: tv);

      late BuildContext pushed;
      unawaited(
        Navigator.of(shell).push(
          MaterialPageRoute<void>(
            builder: (context) {
              pushed = context;
              return const Scaffold();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(MediaQuery.paddingOf(pushed), TvDensity.overscanPadding(tvSize));
    });

    testWidgets('a desktop pushes routes that use every pixel', (tester) async {
      useScreen(tester, tvSize);
      final shell = await pumpApp(tester, device: DeviceProfile.fallback);

      late BuildContext pushed;
      unawaited(
        Navigator.of(shell).push(
          MaterialPageRoute<void>(
            builder: (context) {
              pushed = context;
              return const Scaffold();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(MediaQuery.paddingOf(pushed), EdgeInsets.zero);
    });

    testWidgets('Details keeps its app bar out of the band', (tester) async {
      useScreen(tester, tvSize);
      await pumpDetails(tester, device: tv);

      expect(
        tester.getRect(find.byType(Scaffold)),
        Rect.fromLTRB(
          tvSize.width * 0.05,
          tvSize.height * 0.05,
          tvSize.width * 0.95,
          tvSize.height * 0.95,
        ),
      );
    });

    testWidgets('Details on a desktop fills the window', (tester) async {
      useScreen(tester, tvSize);
      await pumpDetails(tester, device: DeviceProfile.fallback);

      expect(tester.getRect(find.byType(Scaffold)), Offset.zero & tvSize);
    });

    testWidgets('the player keeps its controls on the panel and its picture '
        'off it', (tester) async {
      useScreen(tester, tvSize);
      final harness = PlayerHarness(device: tv);
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 96));
      harness.engine.emitPlaying(true);
      await tester.pumpAndSettle();

      // The seek bar and the transport row are what a remote is aimed at,
      // so they stay inside the band; the video is not cropped to fit it.
      expect(
        tester.getRect(find.byType(PlayerBottomBar)).bottom,
        lessThanOrEqualTo(tvSize.height * 0.95),
      );
      expect(tester.getRect(find.byType(Scaffold)), Offset.zero & tvSize);
    });
  });

  group('the settings sheet', () {
    testWidgets('the last setting of the player sheet stays out of the band', (
      tester,
    ) async {
      // The subtitle and audio menus let their `ListView` take the band out
      // of `MediaQuery` by leaving `padding` null. The settings sheet sets
      // its own padding, which opts out of that, so it has to add the band
      // back itself or its last row scrolls under the cropped edge.
      useScreen(tester, tvSize);
      final harness = PlayerHarness(device: tv);
      await harness.pump(tester);
      await tester.tap(find.byTooltip('Playback settings'));
      await tester.pumpAndSettle();

      // The sheet is longer than the screen, so its last row has to be
      // scrolled to before it is built at all.
      final last = find.textContaining('Bitmap subtitles');
      await tester.scrollUntilVisible(last, 120);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(last).bottom,
        lessThanOrEqualTo(tvSize.height * 0.95),
      );
    });

    testWidgets('a desktop sheet uses the pixels a television may not', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final harness = PlayerHarness(device: DeviceProfile.fallback);
      await harness.pump(tester);
      await tester.tap(find.byTooltip('Playback settings'));
      await tester.pumpAndSettle();

      final last = find.textContaining('Bitmap subtitles');
      await tester.scrollUntilVisible(last, 120);
      await tester.pumpAndSettle();
      expect(tester.getRect(last).bottom, greaterThan(tvSize.height * 0.95));
    });
  });

  group('the Board', () {
    testWidgets('a television gets bigger posters than a window of the same '
        'size', (tester) async {
      await pumpBoard(tester, device: DeviceProfile.fallback);
      final onDesktop = tester.getSize(find.byType(PosterTile).first);

      await pumpBoard(tester, device: tv);
      final onTv = tester.getSize(find.byType(PosterTile).first);

      expect(onTv.width, greaterThan(onDesktop.width));
      expect(onTv.height, greaterThan(onDesktop.height));
    });

    testWidgets('the rows have room for the scaled-up text', (tester) async {
      // The header is text in a box of a fixed height, and the row extent
      // is what the list scrolls by, so a bigger text scale has to come
      // out of the strip rather than out of the bottom of the header.
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        XtremioApp(
          core: FakeCoreClient(
            state: {
              CoreField.board: loadBoardFixture(),
              CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
            },
          ),
          device: tv,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('a large system font grows the row instead of the poster', (
      tester,
    ) async {
      // The header and the caption are text in boxes of a fixed height, so
      // both have to grow with the text -- and the row with them. What may
      // not happen is the poster paying for it: the strip is what is left
      // over between the two boxes, and squeezing it there shrank the
      // picture and, far enough up the scale, went negative.
      useScreen(tester, tvSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      Future<(double poster, double row)> measure(double systemScale) async {
        tester.platformDispatcher.textScaleFactorTestValue = systemScale;
        await tester.pumpWidget(
          XtremioApp(
            core: FakeCoreClient(
              state: {
                CoreField.board: loadBoardFixture(),
                CoreField.continueWatchingPreview:
                    loadContinueWatchingFixture(),
              },
            ),
            device: tv,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'scale $systemScale');
        return (
          tester.getSize(find.byType(PosterImage).first).height,
          tester
              .widget<SliverFixedExtentList>(find.byType(SliverFixedExtentList))
              .itemExtent,
        );
      }

      // 3x on top of the television's own 1.15: past where the old
      // arithmetic drove the picture to nothing.
      final (posterAtOne, rowAtOne) = await measure(1);
      final (posterHuge, rowHuge) = await measure(3);

      expect(posterAtOne, greaterThan(100), reason: 'a real picture');
      expect(
        posterHuge,
        greaterThanOrEqualTo(posterAtOne),
        reason: 'the picture never pays for the text',
      );
      expect(rowHuge, greaterThan(rowAtOne), reason: 'the row grew instead');
    });

    testWidgets('a television gets no scrollbar to drag', (tester) async {
      await pumpBoard(tester, device: tv);

      expect(find.byType(Scrollbar), findsNothing);
    });

    testWidgets('a window keeps its scrollbars', (tester) async {
      await pumpBoard(tester, device: DeviceProfile.fallback);

      expect(find.byType(Scrollbar), findsWidgets);
    });
  });

  group('text scale', () {
    testWidgets('a television scales text up', (tester) async {
      useScreen(tester, tvSize);
      final context = await pumpApp(tester, device: tv);

      expect(MediaQuery.textScalerOf(context).scale(20), 20 * 1.15);
    });

    testWidgets('a phone leaves text alone', (tester) async {
      final context = await pumpApp(tester, device: DeviceProfile.fallback);

      expect(MediaQuery.textScalerOf(context).scale(20), 20);
    });

    testWidgets("a television scales on top of the platform's own scale", (
      tester,
    ) async {
      useScreen(tester, tvSize);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final context = await pumpApp(tester, device: tv);

      expect(MediaQuery.textScalerOf(context).scale(20), 20 * 1.15 * 2);
    });
  });
}
