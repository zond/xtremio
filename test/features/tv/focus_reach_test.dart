import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addon_details_screen.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
import 'package:xtremio/features/board/board_screen.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/diagnostics/diagnostics_screen.dart';
import 'package:xtremio/features/diagnostics/server_storage_screen.dart';
import 'package:xtremio/features/discover/discover_screen.dart';
import 'package:xtremio/features/downloads/downloads_screen.dart';
import 'package:xtremio/features/library/library_screen.dart';
import 'package:xtremio/features/player/playback_tracks.dart';
import 'package:xtremio/features/player/track_menus.dart';
import 'package:xtremio/features/search/search_screen.dart';
import 'package:xtremio/features/settings/settings_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_diagnostics_client.dart';
import '../../support/fake_downloads_client.dart';
import '../../support/fixtures.dart';
import '../../support/player_harness.dart';
import '../../support/tv.dart';

/// Every screen the remote can reach, walked stop by stop under a
/// television profile, checking that this app says where the remote is.
///
/// The audit that started this found focusable controls with no emphasis
/// treatment in twenty files: everything built on Material's own
/// primitives drew Flutter's default focus tint -- an overlay of about a
/// tenth, no outline, deaf to the Bold switch -- and on a projector in a
/// lit room that is no indicator at all. Fixing those twenty was a
/// snapshot. This is what stops there being a twenty-first: a screen added
/// without an indicator fails here rather than being invisible until
/// somebody watches it on a projector.
///
/// [focusMarks] says what "marked" means -- what is drawn on the control
/// the remote is standing on -- and, more usefully, what it does not.
///
/// Each screen is walked twice over: as it is first drawn, and again with
/// something opened over it. The second group is not an extra: a dialog, a
/// menu and a sheet are routes with scopes and surfaces of their own, and
/// they are where most of the controls a viewer presses on a television
/// actually are. The last test in the file is the other half: it reads the
/// source tree, so a *new* screen is a failure here too rather than a
/// screen this file has never heard of.
void main() {
  /// [screen] under a television, in the theme `XtremioApp` would have
  /// given it, with the emphasis turned up -- the setting this whole
  /// mechanism exists for, and the one under which a missing indicator is
  /// most obviously missing.
  ///
  /// [pushed] puts it on the navigator over a blank route, which is how
  /// the app reaches everything that is not one of the shell's five tabs.
  /// That is not a detail of the harness: an [AppBar] grows its back
  /// button only when there is something to pop, and on a protected
  /// addon's detail screen -- installed, official and up to date, so no
  /// Install, Update or Uninstall is drawn -- that button is the only
  /// thing the remote can land on at all.
  Widget onTv(Widget screen, {AppPrefs? prefs, bool pushed = false}) {
    final emphasis = prefs?.focusEmphasis ?? FocusEmphasis.bold;
    return DeviceScope(
      profile: tv,
      child: MaterialApp(
        theme: XtremioApp.themeFor(isTv: true, emphasis: emphasis),
        builder: TvMediaQuery.builder,
        initialRoute: pushed ? '/screen' : '/',
        routes: {
          '/': (_) => pushed ? const Scaffold() : screen,
          if (pushed) '/screen': (_) => screen,
        },
      ),
    );
  }

  /// Preferences that persist nothing, set to bold.
  AppPrefs bold() => AppPrefs.inMemory()..setFocusEmphasis(FocusEmphasis.bold);

  /// Everything the core has to answer for the screens below to settle.
  FakeCoreClient fullCore() => FakeCoreClient(
    state: {
      CoreField.ctx: loadCtxLoggedOutFixture(),
      CoreField.board: loadBoardFixture(),
      CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
      CoreField.discover: loadDiscoverFixture(),
      CoreField.search: loadSearchFixture(),
      CoreField.library: loadLibraryFixture(),
      CoreField.metaDetails: loadMetaDetailsFixture(),
      CoreField.installedAddons: loadInstalledAddonsFixture(),
      CoreField.remoteAddons: loadRemoteAddonsFixture(),
      CoreField.addonDetails: loadAddonDetailsFixture(),
    },
  );

  /// Walks the focus order with Tab, checking every stop.
  ///
  /// Tab and not the D-pad: a directional press is about where things are
  /// on the panel and dead-ends on purpose in several places (a row
  /// swallows a sideways press at its end, the rail swallows up and down
  /// at its ends), so it would visit some of a screen and quietly stop.
  /// Tab order visits every focusable widget that is built, which is what
  /// this wants to be exhaustive about.
  ///
  /// [stops] is a bound, not a count: it goes round the order more than
  /// once on a short screen, which costs nothing and checks nothing twice
  /// that matters.
  Future<void> walkEveryStop(WidgetTester tester, {int stops = 30}) async {
    final seen = <String>{};
    for (var i = 0; i < stops; i++) {
      await press(tester, LogicalKeyboardKey.tab);
      final node = FocusManager.instance.primaryFocus;
      if (node is FocusScopeNode || node == null) continue;
      seen.add(node.debugLabel ?? '${node.context?.widget.runtimeType}');
      expect(
        focusMarks(),
        isNotEmpty,
        reason:
            'the remote can land on a ${node.context?.widget.runtimeType} '
            'with no ring lit on it, no stroke round it and no fill under '
            'it -- nothing a viewer three metres away could find',
      );
    }
    expect(
      seen,
      isNotEmpty,
      reason: 'nothing on this screen can be reached with a remote',
    );
  }

  /// Presses [key] until [reached] answers, and says what it was looking
  /// for when it never does.
  Future<void> pressUntil(
    WidgetTester tester,
    LogicalKeyboardKey key,
    bool Function() reached, {
    required String target,
    int limit = 30,
  }) async {
    for (var i = 0; i < limit && !reached(); i++) {
      await press(tester, key);
    }
    expect(reached(), isTrue, reason: 'the remote never reached $target');
  }

  group('every screen marks what the remote lands on', () {
    testWidgets('the shell, rail and Board together', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: onTv(const RootShell(), prefs: bold()),
        ),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });

    testWidgets('Board', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const BoardScreen())),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });

    testWidgets('Discover', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const DiscoverScreen())),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });

    testWidgets('Search', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const SearchScreen())),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });

    testWidgets('Library', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const LibraryScreen())),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });

    testWidgets('Settings', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const SettingsScreen())),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });

    testWidgets('Addons', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: onTv(const AddonsScreen(), pushed: true),
        ),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });

    testWidgets('an addon in detail', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: onTv(
            const AddonDetailsScreen(
              transportUrl: 'https://v3-cinemeta.strem.io/manifest.json',
            ),
            pushed: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });

    testWidgets('a title in detail', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: onTv(
            const MetaDetailsScreen(type: 'movie', id: 'tt0063350'),
            pushed: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });

    testWidgets('Downloads', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: DownloadsScope(
            client: FakeDownloadsClient(
              registry: DownloadsRegistry.fromJson(loadDownloadsFixture()),
            ),
            child: onTv(const DownloadsScreen(), pushed: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });

    testWidgets('Diagnostics', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: onTv(
            DiagnosticsScreen(client: FakeDiagnosticsClient()),
            pushed: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });

    testWidgets('server storage', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: onTv(
            const ServerStorageScreen(client: _StuckCache()),
            pushed: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });

    testWidgets('the player, with its bar up', (tester) async {
      useScreen(tester, tvSize);
      final player = PlayerHarness(device: tv, prefs: bold());
      await player.pump(tester);
      player.engine.emitDuration(const Duration(minutes: 96));
      player.engine.emitPlaying(true);
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    });
  });

  /// The same walk over what a screen puts *over* itself: a dialog, a
  /// menu, a sheet.
  ///
  /// Each of these is a route with a focus scope of its own, drawn on a
  /// surface of its own, sometimes under a theme of its own -- which is
  /// the shape of every fault this file exists to catch. The base state
  /// walked above is also the state a screen spends the least of its life
  /// in: the controls a viewer presses most on a television are on a menu
  /// that opened over something.
  group('and what a screen opens over itself', () {
    testWidgets('a choice menu on a settings row', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const SettingsScreen())),
      );
      await tester.pumpAndSettle();

      await pressUntil(
        tester,
        LogicalKeyboardKey.arrowDown,
        () => focusIn<DropdownButton<BufferAhead>>(),
        target: 'Buffer ahead',
      );
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text(BufferAhead.wholeFile.label), findsWidgets);
      await walkEveryStop(tester, stops: 12);
    });

    testWidgets('the actions menu on a download', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: DownloadsScope(
            client: FakeDownloadsClient(
              registry: DownloadsRegistry.fromJson(loadDownloadsFixture()),
            ),
            child: onTv(const DownloadsScreen(), pushed: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await pressUntil(
        tester,
        LogicalKeyboardKey.tab,
        () => focusedTooltip() == 'Download actions',
        target: 'a download\'s ⋮',
      );
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('Delete'), findsOneWidget);
      await walkEveryStop(tester, stops: 12);
    });

    testWidgets('the actions sheet on a library item', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const LibraryScreen())),
      );
      await tester.pumpAndSettle();

      await pressUntil(
        tester,
        LogicalKeyboardKey.arrowDown,
        () => focusedTileName(tester) != null,
        target: 'a library tile',
      );
      await press(tester, LogicalKeyboardKey.contextMenu);
      expect(find.byType(BottomSheet), findsOneWidget);
      await walkEveryStop(tester, stops: 12);
    });

    testWidgets('a filter menu, which a television gets in place of a '
        'dropdown', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const LibraryScreen())),
      );
      await tester.pumpAndSettle();

      await pressUntil(
        tester,
        LogicalKeyboardKey.tab,
        () => focusedLabel(tester)?.startsWith('Sort:') ?? false,
        target: 'the Sort button',
      );
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(MenuItemButton), findsWidgets);
      await walkEveryStop(tester, stops: 12);
    });

    testWidgets('the Add addon dialog', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: onTv(const AddonsScreen(), pushed: true),
        ),
      );
      await tester.pumpAndSettle();

      await pressUntil(
        tester,
        LogicalKeyboardKey.arrowUp,
        () => focusedTooltip() == 'Back',
        target: 'the app bar',
        limit: 8,
      );
      await pressUntil(
        tester,
        LogicalKeyboardKey.arrowRight,
        () => focusedTooltip() == 'Add addon',
        target: 'the Add addon button',
        limit: 4,
      );
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(AlertDialog), findsOneWidget);
      await walkEveryStop(tester, stops: 12);
    });

    testWidgets("the player's track menu", (tester) async {
      useScreen(tester, tvSize);
      final player = PlayerHarness(device: tv, prefs: bold());
      await player.pump(tester);
      player.engine.emitDuration(const Duration(minutes: 96));
      player.engine.emitTracks(
        const PlaybackTracks(
          audio: [
            TrackInfo(id: '1', title: 'English'),
            TrackInfo(id: '2', title: 'German'),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowUp);
      await pressUntil(
        tester,
        LogicalKeyboardKey.arrowRight,
        () => focusedTooltip() == 'Audio track (A)',
        target: 'the audio menu button',
      );
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(AudioMenu), findsOneWidget);
      await walkEveryStop(tester, stops: 12);
    });

    testWidgets("the player's settings sheet", (tester) async {
      useScreen(tester, tvSize);
      final player = PlayerHarness(device: tv, prefs: bold());
      await player.pump(tester);
      player.engine.emitDuration(const Duration(minutes: 96));
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowUp);
      await pressUntil(
        tester,
        LogicalKeyboardKey.arrowRight,
        () => focusedTooltip() == 'Playback settings',
        target: 'the settings button',
      );
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(PlayerSettingsSheet), findsOneWidget);
      await walkEveryStop(tester, stops: 20);
    });
  });

  test('every screen in the app is one of them', () {
    // The half of this that survives somebody adding a screen. A file
    // named `*_screen.dart` under `lib/features` is a screen a remote can
    // be pointed at, and there is no way to write one this test walks
    // without also naming it here.
    final covered = {
      'board_screen.dart',
      'discover_screen.dart',
      'search_screen.dart',
      'library_screen.dart',
      'settings_screen.dart',
      'addons_screen.dart',
      'addon_details_screen.dart',
      'meta_details_screen.dart',
      'downloads_screen.dart',
      'diagnostics_screen.dart',
      'server_storage_screen.dart',
      'player_screen.dart',
    };
    final found = Directory('lib/features')
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .where((name) => name.endsWith('_screen.dart'))
        .toSet();

    expect(
      found.difference(covered),
      isEmpty,
      reason: 'a screen with no focus-reach test above it',
    );
    expect(
      covered.difference(found),
      isEmpty,
      reason: 'a screen named here that no longer exists',
    );
  });
}

/// A cache report that never arrives, so the screen settles on the state a
/// television actually sits in while the embedded server is starting: the
/// heading, the refresh and the clean button, and nothing measured yet.
class _StuckCache implements ServerCacheControl {
  const _StuckCache();

  @override
  Future<CacheUsage> cacheUsage() async =>
      throw StateError('server not running');

  @override
  Future<EvictionReport> cleanCacheNow() async =>
      throw StateError('server not running');
}
