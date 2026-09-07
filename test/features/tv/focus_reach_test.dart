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
import 'package:xtremio/features/details/tv_source_row.dart';
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
import 'package:xtremio/widgets/tv_text_field.dart';

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

/// One mount: a screen put under a television, with the observer that
/// counts what it pushes.
///
/// A mount rather than a walk, because proving that a screen opens nothing
/// means pressing one stop at a time on a screen nothing has been pressed
/// on yet -- so the mount is run again for every press.
typedef Mount = Future<Pushed> Function(WidgetTester tester);

/// A screen that opens nothing over itself, and the mount that is driven
/// to prove it.
typedef Claim = ({String screen, String name, Mount mount});

Claim claim(String screen, String name, Mount mount) =>
    (screen: screen, name: name, mount: mount);

/// What a screen has put on its navigator since it was mounted.
///
/// A dialog, a sheet, a menu with a route of its own and another screen are
/// all a push, and [unopened] is about a screen that makes none: counting
/// them is how a claim that used to be a sentence is checked.
class Pushed extends NavigatorObserver {
  int count = 0;

  /// What was pushed last, so a failure can say what appeared.
  Route<dynamic>? last;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) {
    count++;
    last = route;
  }
}

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
/// proved.** [drawn] walks every screen as it is first drawn. [opened]
/// walks what a screen puts *over* itself -- a dialog, a menu, a sheet --
/// which is not an extra: each of those is a route with a scope and a
/// surface of its own, and they are where most of the controls a viewer
/// presses on a television actually are. A screen that opens nothing over
/// itself on a television is in [unopened] instead.
///
/// **Nothing here is excused by writing a reason.** [unopened] used to be
/// a table of prose, and a screen counted as covered the moment somebody
/// wrote a sentence in it: a reviewer listed a screen whose dialog held an
/// unmarked stop, gave the reason "nothing at all, honest.", and the suite
/// stayed green -- and one of the four sentences that were meant seriously
/// was wrong in the same way, about this app, for a month. So an entry
/// there is a *mount* now, and the claim is a measurement:
/// [proveNothingOpens] drives every stop of that screen with the two
/// presses a remote has -- select, and the menu key, which is how a
/// television delivers a hold -- and fails on a route being pushed or a
/// menu opening. A screen with a dialog behind any of its stops cannot be
/// listed there whatever is written about it.
///
/// **Why the claims are checked rather than every screen probed.** The
/// stronger mechanism -- drive every stop of every screen, walk whatever
/// answers -- was built first and thrown away: pressing select on a poster
/// tile pushes a details screen that has no downloads scope over it, on a
/// catalog card a progress bar that never settles, and on a source card a
/// player that wants a real libmpv, so a third of the presses failed for
/// reasons that are about this harness rather than about the app. That
/// would have traded a claim that can be false for a suite that is flaky,
/// which is the same bargain in another currency. So the screens that open
/// something are walked by hand in [opened], where writing the walk is
/// what says the surface exists, and the screens that open nothing say so
/// by being driven.
///
/// All three lists are tables rather than prose, and the tests below are
/// built from them, so a screen cannot be *named* as covered without a
/// walk really running. The last test in the file reads the source tree
/// and requires every `*_screen.dart` to appear in [drawn], and in exactly
/// one of [opened] and [unopened].
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
  ///
  /// [pushes] watches the navigator, and keys the subtree as well: a mount
  /// run a second time with the same widgets would otherwise update the
  /// screen that is already there, state and all, and what
  /// [proveNothingOpens] needs is a screen nothing has been pressed on.
  Widget onTv(
    Widget screen, {
    AppPrefs? prefs,
    bool pushed = false,
    Pushed? pushes,
  }) {
    final emphasis = prefs?.focusEmphasis ?? FocusEmphasis.bold;
    return KeyedSubtree(
      key: pushes == null ? null : ObjectKey(pushes),
      child: DeviceScope(
        profile: tv,
        child: MaterialApp(
          theme: XtremioApp.themeFor(isTv: true, emphasis: emphasis),
          builder: TvMediaQuery.builder,
          navigatorObservers: [?pushes],
          initialRoute: pushed ? '/screen' : '/',
          routes: {
            '/': (_) => pushed ? const Scaffold() : screen,
            if (pushed) '/screen': (_) => screen,
          },
        ),
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

  /// The meta details fixture with WatchHub's stream request failed.
  ///
  /// WatchHub is installed and unprotected in the logged-out profile, so
  /// the card the accounting row draws for it is the removable kind and a
  /// hold on it asks before uninstalling. The failure the fixture already
  /// records is the local addon's, which is protected and offers nothing.
  Map<String, dynamic> metaDetailsWithFailure(String message) {
    final state = loadMetaDetailsFixture();
    final groups = state['streams'] as List<dynamic>;
    (groups[0] as Map<String, dynamic>)['content'] = failedPage(message);
    return state;
  }

  /// The addon details fixture with the protected flag cleared.
  ///
  /// What is recorded is Cinemeta, which every profile protects: the
  /// screen then draws no action at all, and a screen with nothing to
  /// press proves nothing about what its presses open.
  Map<String, dynamic> removableAddonDetails() {
    final details = loadAddonDetailsFixture();
    final local = details['localAddon'] as Map<String, dynamic>;
    final flags = local['flags'] as Map<String, dynamic>;
    flags['protected'] = false;
    return details;
  }

  /// The movie kept offline from another release, finished.
  ///
  /// A source card's hold is then the download affordance, and taking it
  /// asks before dropping the copy already on the device -- the one
  /// `showDialog` the details screen makes on a television.
  FakeDownloadsClient keptFromAnotherRelease() {
    const entry = {
      'metaId': 'tt0063350',
      'videoId': 'tt0063350',
      'name': 'Night of the Living Dead',
      'stream': {'infoHash': 'ffff', 'fileIdx': 0},
      'infoHash': 'ffff',
      'fileIdx': 0,
      'size': 4200000000,
      'downloaded': 4200000000,
      'state': 'complete',
      'path': null,
    };
    return FakeDownloadsClient(
      registry: DownloadsRegistry(
        items: {DownloadView(entry).key: DownloadView(entry)},
      ),
    );
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

  /// Every stop the remote can land on right now.
  ///
  /// The same filter directional traversal applies: a node under an
  /// [ExcludeFocus], or in a route a dialog is standing over, answers
  /// `canRequestFocus` false and is not one.
  List<FocusNode> stopsNow() => FocusManager
      .instance
      .rootScope
      .traversalDescendants
      .where((node) => node is! FocusScopeNode)
      .toList();

  /// What the remote is standing on, named as a failure would have to name
  /// it.
  String focusedName(WidgetTester tester) {
    final node = FocusManager.instance.primaryFocus;
    final context = node?.context;
    if (context == null) return 'nothing';
    final label = focusedTooltip() ?? focusedLabel(tester);
    final type = context.widget.runtimeType;
    return label == null ? '$type' : '$type "$label"';
  }

  /// How many stops the tab order has: it is walked until it comes back
  /// round to where it started.
  Future<int> countStops(WidgetTester tester, {int limit = 40}) async {
    FocusNode? first;
    var stops = 0;
    for (var i = 0; i < limit; i++) {
      await press(tester, LogicalKeyboardKey.tab);
      final node = FocusManager.instance.primaryFocus;
      if (node == null || node is FocusScopeNode) continue;
      if (first == null) {
        first = node;
      } else if (identical(node, first)) {
        break;
      }
      stops++;
    }
    return stops;
  }

  /// Puts the remote on the [index]th stop of a freshly mounted screen.
  Future<void> tabTo(WidgetTester tester, int index) async {
    for (var i = 0; i <= index; i++) {
      await press(tester, LogicalKeyboardKey.tab);
    }
  }

  /// Fails on a stop among [nodes] this app draws nothing on.
  ///
  /// [walkEveryStop] reads the mark off whatever the tab order lands on;
  /// this reads it off a node handed to it, which is what a stop that has
  /// only just appeared -- a snack bar's action, a row that expanded under
  /// the press -- needs, since the order is not walked again.
  Future<void> markEvery(WidgetTester tester, Iterable<FocusNode> nodes) async {
    for (final node in nodes) {
      if (node.context == null) continue;
      node.requestFocus();
      await tester.pumpAndSettle();
      if (!identical(FocusManager.instance.primaryFocus, node)) continue;
      expect(
        focusMarks(),
        isNotEmpty,
        reason:
            'a press left a ${focusedName(tester)} the remote can land on '
            'with no ring lit on it, no stroke round it and no fill under '
            'it',
      );
    }
  }

  /// One press on the stop the remote is standing on: fails if it opened
  /// anything over the screen, and answers with the stops it revealed.
  ///
  /// What counts as opening something is a route being pushed -- a dialog,
  /// a sheet, a popup menu and another screen are all one -- or a
  /// [MenuAnchor] menu, which is the one surface this app draws with no
  /// route of its own. Whatever appears that is neither is more of this
  /// screen, and is walked instead: every stop of it is marked or this
  /// fails too.
  Future<List<FocusNode>> pressAndProve(
    WidgetTester tester,
    Pushed pushed,
    LogicalKeyboardKey key,
  ) async {
    final before = pushed.count;
    final where = focusedName(tester);
    final known = stopsNow().toSet();
    await press(tester, key);
    expect(
      pushed.count,
      before,
      reason:
          '${key.keyLabel} on $where pushed a ${pushed.last.runtimeType}: '
          'this screen opens something over itself, so it belongs in the '
          'walks above rather than here',
    );
    expect(
      find.byType(MenuItemButton),
      findsNothing,
      reason:
          '${key.keyLabel} on $where opened a menu: this screen opens '
          'something over itself, so it belongs in the walks above rather '
          'than here',
    );
    final fresh = stopsNow().where((node) => !known.contains(node)).toList();
    await markEvery(tester, fresh);
    return fresh;
  }

  /// Drives every stop of [mount]'s screen with both presses a remote has,
  /// and with them whatever those presses put in reach.
  ///
  /// Select is the tap and the menu key is the hold ([RemotePress] takes
  /// either a held select or that key), so between them every callback a
  /// stop carries is called. Each press is made on a screen freshly
  /// mounted and tabbed to, because what the press before it did -- opened
  /// a section, played something, left the screen -- must not decide which
  /// stop comes next.
  Future<void> proveNothingOpens(WidgetTester tester, Mount mount) async {
    await mount(tester);
    final stops = await countStops(tester);
    expect(
      stops,
      greaterThan(0),
      reason:
          'nothing on this screen can be reached with a remote, so '
          'driving it proves nothing',
    );
    for (var i = 0; i < stops; i++) {
      for (final key in const [
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.contextMenu,
      ]) {
        final pushed = await mount(tester);
        await tabTo(tester, i);
        // A press that revealed more of the screen is followed one level
        // down, because that is where a television keeps most of its
        // actions: a card opens a row of cards, and the dialog is on a
        // hold two presses in rather than one. Two levels and no more --
        // the walks in [opened] are what reach further than that.
        for (final revealed in await pressAndProve(tester, pushed, key)) {
          if (revealed.context == null) continue;
          revealed.requestFocus();
          await tester.pumpAndSettle();
          if (!identical(FocusManager.instance.primaryFocus, revealed)) {
            continue;
          }
          for (final second in const [
            LogicalKeyboardKey.select,
            LogicalKeyboardKey.contextMenu,
          ]) {
            await pressAndProve(tester, pushed, second);
          }
        }
      }
    }
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
    walk(
      'meta_details_screen.dart',
      'the Uninstall dialog on an addon that answered a stream request '
          'with an error',
      (tester) async {
        useScreen(tester, tvSize);
        await tester.pumpWidget(
          CoreScope(
            client: fullCore({
              CoreField.metaDetails: metaDetailsWithFailure(
                'Failed to fetch: HTTP 502',
              ),
            }),
            child: onTv(
              const MetaDetailsScreen(type: 'movie', id: 'tt0063350'),
              pushed: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // What the addons did other than answer is the last card of the
        // group row, and the dead addon's own card is in the row it opens.
        // The dialog is on a hold, because a button drawn inside a card is
        // not a button a remote can reach.
        await pressUntil(
          tester,
          LogicalKeyboardKey.tab,
          () => focusedLabel(tester) == kSourceAccountingLabel,
          target: 'the card that accounts for the addons',
        );
        await press(tester, LogicalKeyboardKey.select);
        // The accounting card is the right-hand end of the group row, so
        // down lands on the card under it -- the local addon, which is
        // protected and offers no hold -- and the removable one is to the
        // left of that.
        await press(tester, LogicalKeyboardKey.arrowDown);
        await pressUntil(
          tester,
          LogicalKeyboardKey.arrowLeft,
          () => focusedLabel(tester) == 'WatchHub',
          target: "the failed addon's card",
          limit: 8,
        );
        await press(tester, LogicalKeyboardKey.contextMenu);
        expect(find.byType(AlertDialog), findsOneWidget);
        await walkEveryStop(tester, stops: 12);
      },
    ),
    walk(
      'meta_details_screen.dart',
      'the replace dialog a hold on a source card opens',
      (tester) async {
        useScreen(tester, tvSize);
        final downloads = keptFromAnotherRelease();
        addTearDown(downloads.dispose);
        await tester.pumpWidget(
          CoreScope(
            client: fullCore(),
            child: DownloadsScope(
              client: downloads,
              child: onTv(
                const MetaDetailsScreen(type: 'movie', id: 'tt0063350'),
                pushed: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // A group card opens the row of sources under it; the hold on one
        // of those is the download the vertical list draws a button for.
        await pressUntil(
          tester,
          LogicalKeyboardKey.tab,
          () => focusIn<TvSourceGroupCard>(),
          target: 'a group of sources',
        );
        await press(tester, LogicalKeyboardKey.select);
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focusIn<TvSourceCard>(), isTrue);
        await press(tester, LogicalKeyboardKey.contextMenu);
        expect(find.byType(AlertDialog), findsOneWidget);
        await walkEveryStop(tester, stops: 12);
      },
    ),
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

  /// The screens no walk in [opened] covers, each as a mount
  /// [proveNothingOpens] drives: every stop pressed and held, and a route
  /// or a menu appearing is the failure.
  ///
  /// Read on a television. What a phone or a desktop opens over one of
  /// these is not this file's business -- and what a mount here has to be
  /// is the screen in the state where it draws the *most* it can, since a
  /// button that is not built is a button nothing presses. The addon
  /// details mount is an installed, unprotected addon for exactly that
  /// reason: the protected one the walk above uses draws no action at all.
  final unopened = <Claim>[
    // Install, Update, Uninstall and Configure dispatch to the core and
    // report through a snack bar -- which is neither a route nor, on this
    // screen, a focus stop. Written down as what the driving found, not as
    // what lets it be skipped.
    claim('addon_details_screen.dart', 'an addon in detail', (tester) async {
      final pushes = Pushed();
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore({CoreField.addonDetails: removableAddonDetails()}),
          child: onTv(
            const AddonDetailsScreen(
              transportUrl: 'https://v3-cinemeta.strem.io/manifest.json',
            ),
            pushed: true,
            pushes: pushes,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return pushes;
    }),
    // The same shape: every action here reports through a snack bar.
    claim('diagnostics_screen.dart', 'Diagnostics', (tester) async {
      final pushes = Pushed();
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: onTv(
            DiagnosticsScreen(client: FakeDiagnosticsClient()),
            pushed: true,
            pushes: pushes,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return pushes;
    }),
    // And the same for refresh and clean, on a server that is not
    // answering -- which is the state a television sits in while the
    // embedded server starts.
    claim('server_storage_screen.dart', 'server storage', (tester) async {
      final pushes = Pushed();
      useScreen(tester, tvSize);
      await tester.pumpWidget(
        CoreScope(
          client: fullCore(),
          child: onTv(
            const ServerStorageScreen(client: _StuckCache()),
            pushed: true,
            pushes: pushes,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return pushes;
    }),
  ];

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

  /// And the other half of that: a screen that opens nothing is driven
  /// until it has had every press a remote can give it, so the claim is
  /// something this suite found out rather than something somebody wrote.
  group('and a screen that opens nothing is driven until it proves it', () {
    for (final entry in unopened) {
      testWidgets(entry.name, (tester) async {
        await proveNothingOpens(tester, entry.mount);
      });
    }
  });

  /// What "one surface, one indicator" is really a rule about.
  ///
  /// A ring turns the floor's fill off only where the surface owns the ink
  /// that would paint it, and the details screen draws all four cases at
  /// once. Pinned here because the rule is written down in AGENTS.md, and
  /// a rule with no test under it is the sort that drifts into being
  /// wrong.
  testWidgets('a ring turns the fill off only where the surface owns the '
      'ink', (tester) async {
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

    /// The marks on the stop the walk reaches by [label], whether that is
    /// a tooltip or the first text on it.
    Future<Set<FocusMark>> marksOn(String label) async {
      await pressUntil(
        tester,
        LogicalKeyboardKey.tab,
        () => focusedTooltip() == label || focusedLabel(tester) == label,
        target: label,
      );
      return focusMarks();
    }

    // A source card builds its own [InkWell], so it can and does hand it a
    // transparent focus colour: over poster art the floor's near-white
    // wash says nothing the ring has not.
    expect(await marksOn('1080p'), {FocusMark.ring});
    // A chip's ink is Material's and falls through to
    // `ThemeData.focusColor`; the floor can fill one and cannot outline
    // one, so the ring is the half put on by hand.
    expect(await marksOn('Peers per MB'), {FocusMark.ring, FocusMark.fill});
    // The bookmark is an [IconButton] under a [FocusHighlighted]: the
    // floor reaches a Material button with both its marks, and the ring is
    // a third because this one is drawn over a darkened backdrop.
    expect(await marksOn('Add to library'), {
      FocusMark.ring,
      FocusMark.stroke,
      FocusMark.fill,
    });
    // And the app bar's button, which is the floor alone.
    expect(await marksOn('Back'), {FocusMark.stroke, FocusMark.fill});
  });

  testWidgets('and a text field keeps the fill although it owns its ink', (
    tester,
  ) async {
    // The exception with a reason: the field drew a fill of its own -- a
    // quarter of `ColorScheme.primary`, which the Bold switch could not
    // reach -- and the fix was to hand that fill to the floor rather than
    // to take it away, with the ring on top.
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      CoreScope(client: fullCore(), child: onTv(const SearchScreen())),
    );
    await tester.pumpAndSettle();

    await pressUntil(
      tester,
      LogicalKeyboardKey.tab,
      () => focusIn<TvTextField>(),
      target: 'the search field',
    );
    expect(focusMarks(), {FocusMark.ring, FocusMark.fill});
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
    final excused = {for (final entry in unopened) entry.screen};

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
          'a screen both walked with something open and driven to prove it '
          'opens nothing; one of the two is wrong, and the walk is the one '
          'holding the evidence',
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
