import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/board/board_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';
import 'package:xtremio/shell/tv_density.dart';
import 'package:xtremio/widgets/poster_tile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fixtures.dart';
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
