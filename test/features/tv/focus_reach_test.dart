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
import '../../support/text_entry.dart';
import '../../support/tv.dart';

/// One walk: a screen mounted under a television and driven with a remote.
typedef Walk = Future<void> Function(WidgetTester tester);

/// A walk, the `*_screen.dart` it is about, and what it is called.
typedef Case = ({String screen, String name, Walk walk});

Case walk(String screen, String name, Walk walk) =>
    (screen: screen, name: name, walk: walk);

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
/// **Two walks per screen, and the second is the one that has to be
/// declared.** [drawn] walks every screen as it is first drawn. [opened]
/// walks what a screen puts *over* itself -- a dialog, a menu, a sheet --
/// which is not an extra: each of those is a route with a scope and a
/// surface of its own, and they are where most of the controls a viewer
/// presses on a television actually are. A screen that opens nothing over
/// itself on a television is in [unopened] instead, with the reason.
///
/// Both lists are tables rather than prose, and the tests below are built
/// from them, so a screen cannot be *named* as covered without a walk
/// really running: naming was all the old guard checked, which let a
/// screen whose dialog had an unmarked stop pass. The last test in the
/// file reads the source tree and requires every `*_screen.dart` to appear
/// in [drawn], and in exactly one of [opened] and [unopened].
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

  /// Everything the core has to answer for the screens below to settle,
  /// with [overrides] laid over it for a walk that needs a state the
  /// recorded fixtures do not have.
  FakeCoreClient fullCore([
    Map<CoreField, Map<String, dynamic>> overrides = const {},
  ]) => FakeCoreClient(
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
      ...overrides,
    },
  );

  /// An `Err` page: what a catalog whose addon could not answer looks like.
  Map<String, dynamic> failedPage(String message) => {
    'type': 'Err',
    'content': {
      'type': 'Env',
      'content': {'code': 1, 'message': message},
    },
  };

  /// The board fixture with the catalog at [index] failed. Catalog 4 is
  /// the channels addon's, which the logged-out profile has installed and
  /// does not protect -- so the failure card offers Uninstall, which is
  /// the dialog this screen opens over itself.
  Map<String, dynamic> boardWithFailure(int index, String message) {
    final board = loadBoardFixture();
    final catalogs = board['catalogs'] as List<dynamic>;
    ((catalogs[index] as List<dynamic>)[0] as Map<String, dynamic>)['content'] =
        failedPage(message);
    return board;
  }

  /// The query the recorded search fixture answers, so the results the
  /// screen gets back are the recorded ones -- among them the one addon
  /// that failed.
  const searchQuery = 'night of the living dead';

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

  /// The failure card's Uninstall, which is the one thing the failed-addon
  /// section opens a dialog for. The card is behind a summary line the
  /// remote has to open first.
  Future<void> openUninstallDialog(WidgetTester tester, String summary) async {
    await pressUntil(
      tester,
      LogicalKeyboardKey.arrowDown,
      () => focusedLabel(tester) == summary,
      target: 'the "$summary" line',
    );
    await press(tester, LogicalKeyboardKey.select);
    await pressUntil(
      tester,
      LogicalKeyboardKey.tab,
      () => focusedLabel(tester) == 'Uninstall',
      target: "the failed addon's Uninstall",
      limit: 8,
    );
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  /// Every screen as it is first drawn.
  final drawn = <Case>[
    walk('board_screen.dart', 'the shell, rail and Board together', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: onTv(const RootShell(), prefs: bold()),
        ),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    }),
    walk('board_screen.dart', 'Board', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const BoardScreen())),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    }),
    walk('discover_screen.dart', 'Discover', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const DiscoverScreen())),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    }),
    walk('search_screen.dart', 'Search', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const SearchScreen())),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    }),
    walk('library_screen.dart', 'Library', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const LibraryScreen())),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    }),
    walk('settings_screen.dart', 'Settings', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const SettingsScreen())),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    }),
    walk('addons_screen.dart', 'Addons', (tester) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: onTv(const AddonsScreen(), pushed: true),
        ),
      );
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    }),
    walk('addon_details_screen.dart', 'an addon in detail', (tester) async {
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
    }),
    walk('meta_details_screen.dart', 'a title in detail', (tester) async {
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
    }),
    walk('downloads_screen.dart', 'Downloads', (tester) async {
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
    }),
    walk('diagnostics_screen.dart', 'Diagnostics', (tester) async {
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
    }),
    walk('server_storage_screen.dart', 'server storage', (tester) async {
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
    }),
    walk('player_screen.dart', 'the player, with its bar up', (tester) async {
      useScreen(tester, tvSize);
      final player = PlayerHarness(device: tv, prefs: bold());
      await player.pump(tester);
      player.engine.emitDuration(const Duration(minutes: 96));
      player.engine.emitPlaying(true);
      await tester.pumpAndSettle();
      await walkEveryStop(tester);
    }),
  ];

  /// The same walk over what a screen puts *over* itself.
  final opened = <Case>[
    walk('board_screen.dart', 'the Uninstall dialog on a failed catalog', (
      tester,
    ) async {
      // Tall enough for the sliver that accounts for the failures, which
      // is under every row of the board and is not built until it is.
      // Continue watching is emptied for the same reason: it is one more
      // row between the remote and the end.
      useScreen(tester, const Size(1280, 2400));
      await tester.pumpWidget(
        CoreScope(
          client: fullCore({
            CoreField.board: boardWithFailure(4, 'Failed to fetch: HTTP 404'),
            CoreField.continueWatchingPreview: {'items': <Object>[]},
          }),
          child: onTv(const BoardScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await openUninstallDialog(tester, '1 catalog could not be loaded');
      await walkEveryStop(tester, stops: 12);
    }),
    walk('discover_screen.dart', 'the catalog menu on Discover', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(client: fullCore(), child: onTv(const DiscoverScreen())),
      );
      await tester.pumpAndSettle();

      await pressUntil(
        tester,
        LogicalKeyboardKey.tab,
        () => focusedLabel(tester)?.startsWith('Catalog:') ?? false,
        target: 'the Catalog button',
      );
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(MenuItemButton), findsWidgets);
      await walkEveryStop(tester, stops: 12);
    }),
    walk(
      'search_screen.dart',
      'the Uninstall dialog on an addon that could '
          'not be searched',
      (tester) async {
        // A television types on a screen of the platform's own, so the query
        // arrives as a reply on the device channel rather than as key
        // presses. It is the fixture's own query, so what comes back is the
        // recorded result set -- one of whose addons failed.
        useScreen(tester, const Size(1280, 4000));
        answerTextEntry(searchQuery);
        await tester.pumpWidget(
          CoreScope(client: fullCore(), child: onTv(const SearchScreen())),
        );
        await tester.pumpAndSettle();

        await press(tester, LogicalKeyboardKey.tab);
        // Not `press`: confirming a query starts a search, and a progress
        // bar never settles while it is out.
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await settleTextEntry(tester);
        await tester.pumpAndSettle();
        expect(find.text(searchQuery), findsWidgets);

        await openUninstallDialog(tester, '1 addon could not be searched');
        await walkEveryStop(tester, stops: 12);
      },
    ),
    walk('library_screen.dart', 'the actions sheet on a library item', (
      tester,
    ) async {
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
    }),
    walk(
      'library_screen.dart',
      'a filter menu, which a television gets in '
          'place of a dropdown',
      (tester) async {
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
      },
    ),
    walk('settings_screen.dart', 'a choice menu on a settings row', (
      tester,
    ) async {
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
    }),
    walk('addons_screen.dart', 'the Add addon dialog', (tester) async {
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
    }),
    walk('downloads_screen.dart', 'the actions menu on a download', (
      tester,
    ) async {
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
    }),
    walk('player_screen.dart', "the player's track menu", (tester) async {
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
    }),
    walk('player_screen.dart', "the player's settings sheet", (tester) async {
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
    }),
  ];

  /// The screens no walk in [opened] covers, and exactly why. Read on a
  /// television: what a phone or a desktop opens over one of these is not
  /// this file's business, and in two cases is the whole of the answer.
  const unopened = <String, String>{
    'meta_details_screen.dart':
        'its one showDialog is the "replace the copy you already have" '
        'question on a download affordance, and a television draws none: '
        'a TV source row carries a DownloadBadge and no button. The '
        'failed-addon section it also builds expands in place rather than '
        'over anything.',
    'addon_details_screen.dart':
        'Install, Update, Uninstall and Configure dispatch straight to the '
        'core and report through a snack bar; nothing here is asked twice.',
    'diagnostics_screen.dart':
        'every action reports through a snack bar, which is neither a '
        'route nor a focus stop.',
    'server_storage_screen.dart':
        'the same: refresh and clean report through a snack bar.',
  };

  group('every screen marks what the remote lands on', () {
    for (final entry in drawn) {
      testWidgets(entry.name, entry.walk);
    }
  });

  /// Each of these is a route with a focus scope of its own, drawn on a
  /// surface of its own, sometimes under a theme of its own -- which is
  /// the shape of every fault this file exists to catch. The base state
  /// walked above is also the state a screen spends the least of its life
  /// in: the controls a viewer presses most on a television are on a menu
  /// that opened over something.
  group('and what a screen opens over itself', () {
    for (final entry in opened) {
      testWidgets(entry.name, entry.walk);
    }
  });

  test('every screen in the app is walked, and twice where it opens '
      'anything', () {
    // The half of this that survives somebody adding a screen. A file
    // named `*_screen.dart` under `lib/features` is a screen a remote can
    // be pointed at, and there is no way to write one without also
    // putting it in the tables above -- in [drawn], and in either [opened]
    // or [unopened].
    final found = Directory('lib/features')
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .where((name) => name.endsWith('_screen.dart'))
        .toSet();
    final firstWalked = {for (final entry in drawn) entry.screen};
    final secondWalked = {for (final entry in opened) entry.screen};
    final excused = unopened.keys.toSet();

    expect(
      found.difference(firstWalked),
      isEmpty,
      reason: 'a screen with no focus-reach walk over it',
    );
    expect(
      firstWalked.difference(found),
      isEmpty,
      reason: 'a screen walked here that no longer exists',
    );
    expect(
      found.difference(secondWalked.union(excused)),
      isEmpty,
      reason:
          'a screen that is neither walked with something open over it nor '
          'said to open nothing',
    );
    expect(
      secondWalked.union(excused).difference(found),
      isEmpty,
      reason: 'a screen classified here that no longer exists',
    );
    expect(
      secondWalked.intersection(excused),
      isEmpty,
      reason:
          'a screen both walked with something open and excused from it; '
          'the excuse is what the walk disproves',
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
