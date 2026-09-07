import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/focus_theme.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../support/fake_core_client.dart';

/// The dark theme the app builds, before any floor is on it.
ThemeData bare() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF7B5BF5),
    brightness: Brightness.dark,
  ),
);

/// A core whose board is loaded but plans no catalogs, so the shell settles.
FakeCoreClient emptyBoardCore() => FakeCoreClient(
  state: {
    CoreField.board: {
      'selected': {'type': null, 'extra': <Object>[]},
      'catalogs': <Object>[],
      'catalogLabels': <Object>[],
    },
  },
);

void main() {
  group('the floor marks what the app did not draw itself', () {
    test('a focused button is outlined, and only a focused one', () {
      final theme = FocusTheme.apply(bare(), FocusEmphasis.standard);
      final style = theme.filledButtonTheme.style;

      final focused = style?.side?.resolve({WidgetState.focused});
      expect(focused?.color, FocusTheme.stroke);
      expect(focused?.width, FocusTheme.strokeWidth(FocusEmphasis.standard));
      expect(
        style?.side?.resolve({WidgetState.hovered}),
        isNull,
        reason: 'the floor changes the focused state and nothing else',
      );
      expect(style?.overlayColor?.resolve({WidgetState.hovered}), isNull);
    });

    test('every family of control the app uses is reached', () {
      final theme = FocusTheme.apply(bare(), FocusEmphasis.standard);
      final buttons = <String, ButtonStyle?>{
        'filled': theme.filledButtonTheme.style,
        'elevated': theme.elevatedButtonTheme.style,
        'outlined': theme.outlinedButtonTheme.style,
        'text': theme.textButtonTheme.style,
        'icon': theme.iconButtonTheme.style,
        'segmented': theme.segmentedButtonTheme.style,
      };
      for (final entry in buttons.entries) {
        expect(
          entry.value?.side?.resolve({WidgetState.focused})?.color,
          FocusTheme.stroke,
          reason: '${entry.key} buttons are not outlined on focus',
        );
      }
      // Not the chips: a per-state side there throws out of
      // `ChipThemeData.lerp` the moment the theme animates, so every row
      // of chips in the app wears a `FocusMarked` instead.
      expect(theme.chipTheme.side, isNull);
      for (final overlay in [
        theme.switchTheme.overlayColor,
        theme.checkboxTheme.overlayColor,
        theme.radioTheme.overlayColor,
      ]) {
        expect(overlay?.resolve({WidgetState.focused}), isNotNull);
      }
    });

    test('a control with no stroke to give is filled instead', () {
      // `ListTile`, `PopupMenuItem` and a `NavigationRail` destination are
      // all an `InkResponse` with no overlay of their own, which falls
      // through to the theme's focus colour; none of the three takes a
      // per-state shape, so this is the whole of their indicator.
      final standard = FocusTheme.apply(bare(), FocusEmphasis.standard);
      final bold = FocusTheme.apply(bare(), FocusEmphasis.bold);
      expect(standard.focusColor.a, FocusTheme.fill(FocusEmphasis.standard));
      expect(bold.focusColor.a, greaterThan(standard.focusColor.a));
    });

    test('bold thickens the stroke and lifts the fill', () {
      final standard = FocusTheme.apply(bare(), FocusEmphasis.standard);
      final bold = FocusTheme.apply(bare(), FocusEmphasis.bold);
      double width(ThemeData theme) => theme.textButtonTheme.style!.side!
          .resolve({WidgetState.focused})!
          .width;

      expect(width(bold), greaterThan(width(standard)));
      expect(
        FocusTheme.lift(FocusEmphasis.bold),
        greaterThan(FocusTheme.lift(FocusEmphasis.standard)),
      );
    });

    test('what the theme already carried survives', () {
      // The ten-foot density runs first: the minimum target it puts on
      // every icon button must still be there once the floor is on top.
      final theme = FocusTheme.apply(
        TvDensity.theme(bare()),
        FocusEmphasis.bold,
      );
      final style = theme.iconButtonTheme.style;
      expect(
        style?.minimumSize?.resolve({}),
        const Size.square(TvDensity.minTarget),
      );
      expect(
        style?.side?.resolve({WidgetState.focused})?.color,
        FocusTheme.stroke,
      );
    });

    test('the emphasis it was built from is left on the theme', () {
      expect(
        FocusTheme.apply(bare(), FocusEmphasis.bold).extension<FocusFloor>(),
        const FocusFloor(FocusEmphasis.bold),
      );
      expect(bare().extension<FocusFloor>(), isNull);
    });
  });

  group('the switch reaches it', () {
    /// The floor in force where the shell is drawn, or null where none is.
    FocusEmphasis? floorIn(WidgetTester tester) => FocusTheme.emphasisIn(
      tester.element(
        find.byType(NavigationBar).evaluate().isEmpty
            ? find.byType(NavigationRail)
            : find.byType(NavigationBar),
      ),
    );

    testWidgets('a television gets the floor, and flipping it rebuilds', (
      tester,
    ) async {
      final prefs = AppPrefs.inMemory();
      await tester.pumpWidget(
        XtremioApp(
          core: emptyBoardCore(),
          prefs: prefs,
          device: const DeviceProfile(isTv: true, hasTouch: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(floorIn(tester), FocusEmphasis.standard);

      await prefs.setFocusEmphasis(FocusEmphasis.bold);
      await tester.pumpAndSettle();
      expect(floorIn(tester), FocusEmphasis.bold);
    });

    testWidgets('a television pins focus to being drawn, and only one does', (
      tester,
    ) async {
      // Flutter starts Android at [FocusHighlightMode.touch], where an
      // ink paints no focus highlight at all and `DropdownButton` fills
      // the *selected* entry of an open menu with the focus colour. Both
      // are wrong on a device whose only way around is focus.
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      await tester.pumpWidget(
        XtremioApp(
          core: emptyBoardCore(),
          prefs: AppPrefs.inMemory(),
          device: const DeviceProfile(isTv: true, hasTouch: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTraditional,
      );

      await tester.pumpWidget(
        XtremioApp(core: emptyBoardCore(), prefs: AppPrefs.inMemory()),
      );
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.automatic,
        reason: 'off a television the machine decides, and it is put back',
      );
    });

    testWidgets('so nothing but the focused entry of a menu is filled', (
      tester,
    ) async {
      // The floor raised [ThemeData.focusColor] to a near-white 0.44 to
      // mean "the remote is here", and `DropdownButton` is the one place
      // Flutter reads that colour to mean something else: in touch mode
      // it paints the selected entry of its open menu with it, on a row
      // nothing is focused on. A television with a touchscreen, which
      // `DeviceProfile` allows for, opens that menu with a tap.
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      final theme = XtremioApp.themeFor(
        isTv: true,
        emphasis: FocusEmphasis.bold,
      );
      Widget dropdown({required bool pinned}) {
        final app = MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: DropdownButton<int>(
                value: 1,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('zero')),
                  DropdownMenuItem(value: 1, child: Text('one')),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
        );
        return pinned ? AlwaysShowFocus(child: app) : app;
      }

      List<Color?> menuFills(WidgetTester tester) => [
        for (final ink in tester.widgetList<Ink>(find.byType(Ink)))
          switch (ink.decoration) {
            final BoxDecoration decoration => decoration.color,
            _ => null,
          },
      ];

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      await tester.pumpWidget(dropdown(pinned: false));
      await tester.tap(find.text('one'));
      await tester.pumpAndSettle();
      expect(
        menuFills(tester),
        contains(theme.focusColor),
        reason: 'what the app is protecting itself from',
      );

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      await tester.pumpWidget(dropdown(pinned: true));
      await tester.tap(find.text('one'));
      await tester.pumpAndSettle();
      expect(menuFills(tester), isNot(contains(theme.focusColor)));
      expect(
        FocusManager.instance.primaryFocus?.context,
        isNotNull,
        reason: 'the entry that is filled now is the one holding focus',
      );
    });

    testWidgets('off a television nothing is marked differently', (
      tester,
    ) async {
      // The emphasis is a choice about a room and a panel, made with a
      // remote; a desktop draws Material's own tint like everything else
      // on the machine.
      await tester.pumpWidget(
        XtremioApp(core: emptyBoardCore(), prefs: AppPrefs.inMemory()),
      );
      await tester.pumpAndSettle();
      expect(floorIn(tester), isNull);
    });
  });
}
