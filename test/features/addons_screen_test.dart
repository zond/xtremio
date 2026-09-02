import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addon_details_screen.dart';
import 'package:xtremio/features/addons/addon_tile.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
import 'package:xtremio/shell/external_link.dart';

import '../support/fake_core_client.dart';
import '../support/fake_link_opener.dart';
import '../support/fixtures.dart';

void main() {
  const cinemeta = 'https://v3-cinemeta.strem.io/manifest.json';
  const youtube = 'https://v3-channels.strem.io/manifest.json';
  const kitsu = 'https://anime-kitsu.strem.fun/manifest.json';

  // The scopes sit above MaterialApp, as in the app, so pushed routes see
  // them.
  Widget harness(FakeCoreClient core, [FakeLinkOpener? opener]) => CoreScope(
    client: core,
    child: ExternalLinkScope(
      opener: opener ?? FakeLinkOpener(),
      child: const MaterialApp(home: AddonsScreen()),
    ),
  );

  FakeCoreClient fakeCore({
    Map<String, dynamic>? installed,
    Map<String, dynamic>? remote,
    Map<String, dynamic>? ctx,
  }) => FakeCoreClient(
    state: {
      CoreField.installedAddons: installed ?? loadInstalledAddonsFixture(),
      CoreField.remoteAddons: remote ?? loadRemoteAddonsFixture(),
      // For the pushed details screen, so it settles instead of spinning.
      CoreField.addonDetails: loadAddonDetailsFixture(),
      CoreField.ctx: ctx ?? loadCtxLoggedOutFixture(),
    },
  );

  /// The type option [label] in the filter (the tiles carry type labels
  /// too).
  Finder typeOption(String label) => find.descendant(
    of: find.byType(SegmentedButton<int>),
    matching: find.text(label),
  );

  /// The logged-out ctx with [flags] applied to the profile and [extra]
  /// manifest URLs appended to its addons.
  Map<String, dynamic> ctxWith({
    bool addonsLocked = false,
    List<String> extra = const [],
  }) {
    final ctx = loadCtxLoggedOutFixture();
    final profile = ctx['profile'] as Map<String, dynamic>;
    profile['addonsLocked'] = addonsLocked;
    profile['addons'] = [
      ...profile['addons'] as List<dynamic>,
      for (final url in extra)
        {
          'manifest': {'id': url, 'version': '1.0.0', 'name': url},
          'transportUrl': url,
          'flags': {'official': false, 'protected': false},
        },
    ];
    return ctx;
  }

  /// Tall enough for every installed tile to be built.
  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  List<CoreAction> ctxActions(FakeCoreClient core) => [
    for (final action in core.dispatched)
      if (action.action['action'] == 'Ctx') action,
  ];

  List<CoreAction> loads(FakeCoreClient core, CoreField field) => [
    for (final action in core.dispatched)
      if (action.field == field && action.action['action'] == 'Load') action,
  ];

  Map<String, dynamic> installedDescriptor(String transportUrl) =>
      InstalledAddonsState.fromJson(loadInstalledAddonsFixture()).addons
          .singleWhere((addon) => addon.transportUrl == transportUrl)
          .json;

  Map<String, dynamic> communityDescriptor(String transportUrl) =>
      RemoteAddonsState.fromJson(loadRemoteAddonsFixture()).addons
          .singleWhere((addon) => addon.transportUrl == transportUrl)
          .json;

  Future<void> openMenuOf(WidgetTester tester, String name) async {
    final tile = find.ancestor(
      of: find.text(name),
      matching: find.byType(AddonTile),
    );
    await tester.tap(
      find.descendant(of: tile, matching: find.byIcon(Icons.more_vert)),
    );
    await tester.pumpAndSettle();
  }

  /// The community search box (the catalog DropdownMenu has a TextField
  /// of its own).
  final Finder searchField = find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.decoration?.hintText == 'Search addons',
  );

  Future<void> openCommunity(WidgetTester tester) async {
    await tester.tap(find.text('Community'));
    await tester.pumpAndSettle();
  }

  testWidgets('loads both lists on mount, renders installed, unloads both', (
    tester,
  ) async {
    useTallScreen(tester);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    expect(core.dispatched, hasLength(2));
    final installed = loads(core, CoreField.installedAddons).single;
    expect(
      installed.action,
      CoreActions.loadInstalledAddons(const InstalledAddonsRequest()).action,
    );
    expect(installed.action['args']['args'], {
      'request': {'type': null},
    });
    final remote = loads(core, CoreField.remoteAddons).single;
    expect(remote.action, CoreActions.loadRemoteAddons(null).action);
    expect(remote.action['args'], {
      'model': 'CatalogWithFilters',
      'args': null,
    });

    expect(find.text('Addons'), findsOneWidget);
    for (final name in [
      'Cinemeta',
      'YouTube',
      'WatchHub',
      'Public Domain Movies',
      'OpenSubtitles v3',
      'Local Files (without catalog support)',
    ]) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text('v3.0.14'), findsOneWidget);
    expect(find.textContaining('The official addon'), findsOneWidget);
    // Type filter: All plus every type an installed addon serves.
    final segments = find.byType(SegmentedButton<int>);
    expect(segments, findsOneWidget);
    for (final label in ['All', 'Movies', 'Series', 'Channels', 'Other']) {
      expect(
        find.descendant(of: segments, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(tester.widget<SegmentedButton<int>>(segments).selected, {0});

    await tester.pumpWidget(const SizedBox());
    expect(core.dispatched, hasLength(4));
    expect(
      [for (final action in core.dispatched.skip(2)) action.field],
      [CoreField.installedAddons, CoreField.remoteAddons],
    );
    for (final action in core.dispatched.skip(2)) {
      expect(action.action, CoreActions.unload(action.field!).action);
    }
    expect(core.dispatched.where((a) => a.field == null), isEmpty);
  });

  testWidgets('selecting a type dispatches its request verbatim', (
    tester,
  ) async {
    useTallScreen(tester);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(typeOption('Series'));
    await tester.pump();

    final option = InstalledAddonsState.fromJson(loadInstalledAddonsFixture())
        .types
        .singleWhere((type) => type.type == 'series');
    expect(core.dispatched, hasLength(3));
    expect(core.dispatched.last.field, CoreField.installedAddons);
    expect(
      core.dispatched.last.action,
      CoreActions.loadInstalledAddons(option.request).action,
    );
    expect(core.dispatched.last.action['args']['args']['request'], {
      'type': 'series',
    });
  });

  testWidgets('a protected addon has no Uninstall; Uninstall sends the '
      'whole descriptor', (tester) async {
    useTallScreen(tester);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await openMenuOf(tester, 'Cinemeta');
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('Uninstall'), findsNothing);
    expect(find.text('Configure'), findsNothing);
    await tester.tapAt(Offset.zero); // dismiss
    await tester.pumpAndSettle();

    await openMenuOf(tester, 'YouTube');
    await tester.tap(find.text('Uninstall'));
    await tester.pumpAndSettle();

    final actions = ctxActions(core);
    expect(actions, hasLength(1));
    expect(actions.single.field, CoreField.ctx);
    expect(actions.single.action['args']['action'], 'UninstallAddon');
    expect(actions.single.action['args']['args'], installedDescriptor(youtube));
  });

  testWidgets('Details (and a tap on the tile) open the details screen', (
    tester,
  ) async {
    useTallScreen(tester);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await openMenuOf(tester, 'WatchHub');
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    expect(find.byType(AddonDetailsScreen), findsOneWidget);
    expect(
      tester
          .widget<AddonDetailsScreen>(find.byType(AddonDetailsScreen))
          .transportUrl,
      'https://watchhub.strem.io/manifest.json',
    );
    expect(
      loads(core, CoreField.addonDetails).single.action,
      CoreActions.loadAddonDetails('https://watchhub.strem.io/manifest.json')
          .action,
    );
  });

  testWidgets('a tap during the pop of one details screen keeps the next', (
    tester,
  ) async {
    useTallScreen(tester);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    // Open WatchHub, go back, and tap YouTube while WatchHub's route is
    // still animating out (the list underneath is already tappable).
    await tester.tap(find.text('WatchHub'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(AddonDetailsScreen))).pop();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(
      find.ancestor(of: find.text('YouTube'), matching: find.byType(AddonTile)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AddonDetailsScreen), findsOneWidget);
    // The popped screen's dispose must not unload the field the new one
    // has just loaded: Load, Load, and nothing after.
    expect(
      [
        for (final action in core.dispatched)
          if (action.field == CoreField.addonDetails) action.action,
      ],
      [
        CoreActions.loadAddonDetails('https://watchhub.strem.io/manifest.json')
            .action,
        CoreActions.loadAddonDetails(youtube).action,
      ],
    );

    // The surviving screen still unloads on its own exit.
    await tester.pumpWidget(const SizedBox());
    expect(
      core.dispatched
          .where((a) => a.field == CoreField.addonDetails)
          .map((a) => a.action)
          .where((a) => a['action'] == 'Unload'),
      hasLength(1),
    );
  });

  testWidgets('a configurable installed addon offers Configure', (
    tester,
  ) async {
    useTallScreen(tester);
    final installed = loadInstalledAddonsFixture();
    final catalog = installed['catalog'] as List<dynamic>;
    (catalog[2]
            as Map<
              String,
              dynamic
            >)['manifest']['behaviorHints']['configurable'] =
        true;
    final core = fakeCore(installed: installed);
    final opener = FakeLinkOpener();
    await tester.pumpWidget(harness(core, opener));
    await tester.pumpAndSettle();

    await openMenuOf(tester, 'WatchHub');
    await tester.tap(find.text('Configure'));
    await tester.pumpAndSettle();

    expect(
      opener.opened.single.toString(),
      'https://watchhub.strem.io/configure',
    );
    expect(ctxActions(core), isEmpty);
  });

  testWidgets('Add addon asks for a manifest URL and opens its details', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add addon'));
    await tester.pumpAndSettle();
    expect(find.byType(AddAddonDialog), findsOneWidget);

    // Not a URL: stays open, tells the user, loads nothing.
    await tester.enterText(find.byType(TextField), 'cinemeta');
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(AddAddonDialog), findsOneWidget);
    expect(find.text(AddAddonDialog.invalidMessage), findsOneWidget);
    expect(loads(core, CoreField.addonDetails), isEmpty);

    await tester.enterText(find.byType(TextField), ' $cinemeta ');
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(AddAddonDialog), findsNothing);
    expect(find.byType(AddonDetailsScreen), findsOneWidget);
    final load = loads(core, CoreField.addonDetails).single;
    expect(load.action, CoreActions.loadAddonDetails(cinemeta).action);
    expect(load.action['args']['args'], {'transportUrl': cinemeta});
  });

  test('AddAddonDialog.parse accepts http(s) and stremio URLs only', () {
    expect(AddAddonDialog.parse(cinemeta), cinemeta);
    expect(
      AddAddonDialog.parse('stremio://v3-cinemeta.strem.io/manifest.json'),
      'stremio://v3-cinemeta.strem.io/manifest.json',
    );
    expect(
      AddAddonDialog.parse('http://127.0.0.1:11470/manifest.json'),
      isNotNull,
    );
    expect(AddAddonDialog.parse(''), isNull);
    expect(AddAddonDialog.parse('cinemeta'), isNull);
    expect(AddAddonDialog.parse('file:///etc/passwd'), isNull);
    expect(AddAddonDialog.parse('https://'), isNull);
  });

  testWidgets('community: installed comes from the profile, Install sends '
      'the descriptor, configurationRequired gets Configure', (tester) async {
    useTallScreen(tester);
    final core = fakeCore(ctx: ctxWith(extra: [kitsu]));
    final opener = FakeLinkOpener();
    await tester.pumpWidget(harness(core, opener));
    await tester.pumpAndSettle();
    await openCommunity(tester);

    // Catalog menu and types come from the selectable.
    final menu = find.byType(DropdownMenu<int>);
    expect(
      find.descendant(of: menu, matching: find.text('Community')),
      findsWidgets,
    );
    final segments = find.byType(SegmentedButton<int>);
    for (final label in ['All', 'Movies', 'Series', 'Podcasts']) {
      expect(
        find.descendant(of: segments, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(find.text('Anime Kitsu'), findsOneWidget);

    FilledButton trailingOf(String name) {
      final tile = find.ancestor(
        of: find.text(name),
        matching: find.byType(AddonTile),
      );
      return tester.widget<FilledButton>(
        find.descendant(of: tile, matching: find.byType(FilledButton)),
      );
    }

    // Anime Kitsu is in ctx.profile.addons: "Installed", disabled.
    final installed = trailingOf('Anime Kitsu');
    expect((installed.child as Text).data, 'Installed');
    expect(installed.onPressed, isNull);

    // AfterCredits is not: Install sends the catalog's descriptor.
    final install = trailingOf('AfterCredits');
    expect((install.child as Text).data, 'Install');
    await tester.tap(find.byWidget(install));
    await tester.pump();
    final actions = ctxActions(core);
    expect(actions, hasLength(1));
    expect(actions.single.field, CoreField.ctx);
    expect(actions.single.action['args']['action'], 'InstallAddon');
    expect(
      actions.single.action['args']['args'],
      communityDescriptor(
        'https://aftercredits.almosteffective.com/manifest.json',
      ),
    );

    // AIOStatus requires configuration: Configure opens its page instead.
    await tester.enterText(searchField, 'aiostatus');
    await tester.pumpAndSettle();
    expect(find.byType(AddonTile), findsOneWidget);
    final configure = trailingOf('AIOStatus');
    expect((configure.child as Text).data, 'Configure');
    await tester.tap(find.byWidget(configure));
    await tester.pumpAndSettle();
    expect(opener.opened.map((u) => u.toString()), [
      'https://p01--status--sdfgdgfsgdfs--s2qq-tktv.code.run/configure',
    ]);
    expect(ctxActions(core), hasLength(1));
  });

  testWidgets('community search filters by name or description', (
    tester,
  ) async {
    useTallScreen(tester);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    await openCommunity(tester);

    await tester.enterText(searchField, 'KITSU');
    await tester.pumpAndSettle();
    expect(find.byType(AddonTile), findsOneWidget);
    expect(find.text('Anime Kitsu'), findsOneWidget);

    await tester.enterText(searchField, 'no such addon anywhere');
    await tester.pumpAndSettle();
    expect(find.byType(AddonTile), findsNothing);
    expect(find.text('No addons match'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.byType(AddonTile), findsWidgets);
    expect(find.text('AfterCredits'), findsOneWidget);
    // Searching never touches the engine.
    expect(core.dispatched, hasLength(2));
  });

  testWidgets('community catalog and type options dispatch their requests', (
    tester,
  ) async {
    useTallScreen(tester);
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    await openCommunity(tester);
    final selectable = RemoteAddonsState.fromJson(loadRemoteAddonsFixture())
        .selectable;

    await tester.tap(typeOption('Movies'));
    await tester.pump();
    final movies = selectable.types.singleWhere((t) => t.label == 'movie');
    expect(core.dispatched.last.field, CoreField.remoteAddons);
    expect(
      core.dispatched.last.action,
      CoreActions.loadRemoteAddons(movies.request).action,
    );

    await tester.tap(find.byType(DropdownMenu<int>));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(MenuItemButton),
            matching: find.text('Official'),
          )
          .last,
    );
    await tester.pumpAndSettle();
    final official = selectable.catalogs.singleWhere(
      (c) => c.label == 'Official',
    );
    expect(core.dispatched, hasLength(4));
    expect(
      core.dispatched.last.action,
      CoreActions.loadRemoteAddons(official.request).action,
    );
  });

  testWidgets('community: a failed catalog shows the error and retries', (
    tester,
  ) async {
    final remote = loadRemoteAddonsFixture();
    final page = (remote['catalog'] as List<dynamic>).single;
    page['content'] = {
      'type': 'Err',
      'content': {
        'type': 'Env',
        'content': {'code': 4, 'message': 'connection refused'},
      },
    };
    final core = fakeCore(remote: remote);
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
    await openCommunity(tester);

    expect(find.text('connection refused'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(core.dispatched, hasLength(3));
    expect(
      core.dispatched.last.action,
      CoreActions.loadRemoteAddons(
        ResourceRequest.fromJson(remote['selected']['request']),
      ).action,
    );
  });

  testWidgets('addonsLocked: banner, Install and Uninstall disabled', (
    tester,
  ) async {
    useTallScreen(tester);
    final core = fakeCore(ctx: ctxWith(addonsLocked: true));
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    expect(find.textContaining('Addons are locked'), findsOneWidget);
    await openMenuOf(tester, 'YouTube');
    final uninstall = tester.widget<PopupMenuItem<Object?>>(
      find.ancestor(
        of: find.text('Uninstall'),
        matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
      ),
    );
    expect(uninstall.enabled, isFalse);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await openCommunity(tester);
    final install = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Install').first,
    );
    expect(install.onPressed, isNull);
    expect(ctxActions(core), isEmpty);
  });

  testWidgets('a failed addon mutation shows the engine message', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();

    core.emit(
      const RuntimeCoreEvent({
        'event': 'Error',
        'args': {
          'error': {
            'type': 'Other',
            'code': 3,
            'message': 'Addon is already installed',
          },
          'source': {
            'event': 'AddonInstalled',
            'args': {'transport_url': kitsu, 'id': 'community.anime.kitsu'},
          },
        },
      }),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Addon is already installed'), findsOneWidget);
  });
}
