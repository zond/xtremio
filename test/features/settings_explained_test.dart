import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/settings/settings_screen.dart';
import 'package:xtremio/features/update/app_updates.dart';
import 'package:xtremio/features/update/check_for_updates_tile.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/explained.dart';
import 'package:xtremio/widgets/internet_status_tile.dart';
import 'package:xtremio/widgets/readout.dart';
import 'package:xtremio/widgets/remote_press.dart';

import '../support/explained.dart';
import '../support/fake_core_client.dart';
import '../support/fake_updates.dart';
import '../support/fixtures.dart';
import '../support/tv.dart';

/// Settings rows are their titles, and what they mean opens from their icon
/// or a held OK ([Explained]).
void main() {
  /// Settings, signed in, with the internet row and the update row drawn,
  /// on [profile], laid out tall enough that every row is built at once.
  Future<void> pumpSettings(
    WidgetTester tester, {
    DeviceProfile profile = DeviceProfile.fallback,
    Size size = const Size(900, 6000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final internet = InternetStatusCheck(
      fetch: () async => 'ip=203.0.113.7\nloc=SE\n',
    );
    addTearDown(internet.dispose);
    await internet.recheck();
    final source = FakeReleaseSource(release: sampleRelease(tag: 'v0.1.13'));
    await tester.pumpWidget(
      DeviceScope(
        profile: profile,
        child: InternetStatusScope(
          check: internet,
          child: CoreScope(
            client: FakeCoreClient(
              state: {CoreField.ctx: loadCtxLoggedInFixture()},
            ),
            initInfo: const CoreInitInfo(
              serverBaseUrl: null,
              schemaVersion: 25,
            ),
            child: AppUpdatesScope(
              updates: fakeUpdates(source: source),
              child: const MaterialApp(home: SettingsScreen()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The line under a row's title, or null when the row is its title.
  String? lineUnder(WidgetTester tester, String title) {
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
    );
    final subtitle = tile.subtitle;
    return subtitle is Text ? subtitle.data : null;
  }

  testWidgets('every row has the control, and nothing else does', (
    tester,
  ) async {
    await pumpSettings(tester);
    final tiles = find.byType(ListTile);
    expect(tiles, findsAtLeastNWidgets(25));
    for (final element in tiles.evaluate()) {
      final tile = element.widget as ListTile;
      final title = (tile.title! as Text).data;
      final row = element.findAncestorWidgetOfExactType<Explained>();
      expect(row, isNotNull, reason: '"$title" has no explanation');
      expect(row!.title, title, reason: 'the explanation is headed by it');
      expect(row.explanation.trim(), isNotEmpty);
      expect(
        find.descendant(
          of: find.byElementPredicate((e) => e == element),
          matching: find.byTooltip(Explained.tooltip),
        ),
        findsOneWidget,
        reason: '"$title" has no icon to open it',
      );
    }
    // One icon per row: nothing outside a row grew one.
    expect(
      find.byTooltip(Explained.tooltip),
      findsNWidgets(tiles.evaluate().length),
    );
  });

  testWidgets('the icon opens the row\'s own words, and Close shuts them', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(
      find.text('When an episode ends, the next one starts.'),
      findsNothing,
      reason: 'the row is its title',
    );
    await openExplanation(tester, 'Binge watching');
    final dialog = find.byType(ExplanationDialog);
    expect(
      find.descendant(of: dialog, matching: find.text('Binge watching')),
      findsOneWidget,
    );
    expect(
      inExplanation('When an episode ends, the next one starts.'),
      findsOneWidget,
    );
    await closeExplanation(tester);

    // The switch is untouched by the icon: what the row does is the row's.
    final binge = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('setting-bingeWatching')),
    );
    final before = binge.value;
    await openExplanation(tester, 'Binge watching');
    await closeExplanation(tester);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('setting-bingeWatching')),
          )
          .value,
      before,
    );
  });

  testWidgets('a row whose line is a value keeps it; the others are their '
      'titles', (tester) async {
    await pumpSettings(tester);
    final email = ProfileState.fromCtx(loadCtxLoggedInFixture()).user!.email;

    // State, not explanation.
    expect(lineUnder(tester, email), 'Signed in');
    expect(lineUnder(tester, 'Status'), isNotNull);
    expect(lineUnder(tester, 'Peer discovery'), 'Unknown');
    expect(lineUnder(tester, 'stremio-core storage schema'), 'v25');
    expect(lineUnder(tester, InternetStatusTile.connected), 'SE · 203.0.113.7');
    expect(lineUnder(tester, CheckForUpdatesTile.title), startsWith('This is'));

    // Explanation, which moved.
    for (final title in [
      'Addons',
      'Downloads',
      'Server storage',
      'Clear the cache',
      'Diagnostics',
      'Open source licences',
      'Play test torrent',
      'Play test HTTP stream',
      'Download test torrent',
    ]) {
      expect(lineUnder(tester, title), isNull, reason: title);
    }
    for (final title in [
      'Binge watching',
      'Pause when minimised',
      'Hardware decoding',
      'Esc leaves fullscreen',
      'Hide spoilers',
      'Share while idle',
      'Verbose logging',
    ]) {
      final tile = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text(title),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(tile.subtitle, isNull, reason: title);
    }
    // A value row's explanation says what the value is.
    await openExplanation(tester, 'Peer discovery');
    expect(
      find.descendant(
        of: find.byType(ExplanationDialog),
        matching: find.textContaining('finds more people'),
      ),
      findsOneWidget,
    );
    await closeExplanation(tester);
  });

  group('on a television', () {
    Future<void> pumpTv(WidgetTester tester) =>
        pumpSettings(tester, profile: tv, size: tvSize);

    /// Presses down until the focused control reads [label].
    Future<void> downTo(WidgetTester tester, String label) async {
      for (var i = 0; i < 60 && focusedLabel(tester) != label; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedLabel(tester), label);
    }

    Future<void> holdSelect(WidgetTester tester) => hold(
      tester,
      LogicalKeyboardKey.select,
      RemotePress.holdDuration + const Duration(milliseconds: 100),
    );

    testWidgets('a held OK on a row opens its words, and Back puts the '
        'remote back on the row', (tester) async {
      await pumpTv(tester);
      expect(find.byTooltip(Explained.tooltip), findsNothing);
      await downTo(tester, 'Binge watching');
      final binge = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('setting-bingeWatching')),
      );

      await holdSelect(tester);
      expect(
        inExplanation('When an episode ends, the next one starts.'),
        findsOneWidget,
      );
      expect(focusedLabel(tester), ExplanationDialog.closeLabel);

      await systemBack(tester);
      expect(find.byType(ExplanationDialog), findsNothing);
      expect(focusedLabel(tester), 'Binge watching');
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('setting-bingeWatching')),
            )
            .value,
        binge.value,
        reason: 'the hold flipped nothing',
      );
    });

    testWidgets('and on a row that is read, not pressed', (tester) async {
      await pumpTv(tester);
      await downTo(tester, 'Peer discovery');
      expect(focusIn<Readout>(), isTrue);

      await holdSelect(tester);
      expect(
        find.descendant(
          of: find.byType(ExplanationDialog),
          matching: find.textContaining('finds more people'),
        ),
        findsOneWidget,
      );
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(ExplanationDialog), findsNothing);
      expect(focusedLabel(tester), 'Peer discovery');
    });

    testWidgets('a short OK on a menu row still opens the menu', (
      tester,
    ) async {
      await pumpTv(tester);
      await downTo(tester, '10 s');
      expect(focusIn<DropdownButton<int>>(), isTrue);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('30 s'), findsWidgets, reason: 'the menu is open');
      expect(find.byType(ExplanationDialog), findsNothing);
    });
  });
}
