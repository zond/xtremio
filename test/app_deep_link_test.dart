import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addon_details_screen.dart';

import 'support/fake_core_client.dart';
import 'support/fake_deep_links.dart';
import 'support/fake_downloads_client.dart';
import 'support/fixtures.dart';

void main() {
  const torrentio =
      'stremio://torrentio.strem.fun:8080/providers=yts/manifest.json?v=2';
  const cinemeta = 'stremio://v3-cinemeta.strem.io/manifest.json';

  /// The details fixture with nothing installed under that URL, so the
  /// screen offers Install.
  Map<String, dynamic> notInstalled() {
    final json = loadAddonDetailsFixture();
    json['localAddon'] = null;
    return json;
  }

  /// A core with everything the shell and a pushed details screen need to
  /// settle instead of spinning.
  FakeCoreClient fakeCore() => FakeCoreClient(
    state: {
      CoreField.ctx: loadCtxLoggedOutFixture(),
      CoreField.addonDetails: notInstalled(),
      CoreField.board: {
        'selected': {'type': null, 'extra': <Object>[]},
        'catalogs': <Object>[],
        'catalogLabels': <Object>[],
      },
    },
  );

  /// Every `addon_details` action the core was handed, as JSON.
  List<Map<String, dynamic>> detailsActions(FakeCoreClient core) => [
    for (final action in core.dispatched)
      if (action.field == CoreField.addonDetails) action.toJson(),
  ];

  /// The transport URL the details screen on screen was built with.
  String screenUrl(WidgetTester tester) => tester
      .widget<AddonDetailsScreen>(find.byType(AddonDetailsScreen))
      .transportUrl;

  Future<FakeDeepLinks> pumpApp(
    WidgetTester tester,
    FakeCoreClient core, {
    String? initial,
  }) async {
    final links = FakeDeepLinks(initial: initial);
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    await tester.pumpWidget(
      XtremioApp(core: core, deepLinks: links, downloads: downloads),
    );
    await tester.pumpAndSettle();
    return links;
  }

  testWidgets('a stremio:// link opens the addon details screen for the URL '
      'exactly as it arrived', (tester) async {
    final core = fakeCore();
    final links = await pumpApp(tester, core);

    links.send(torrentio);
    await tester.pumpAndSettle();

    expect(find.byType(AddonDetailsScreen), findsOneWidget);
    // Port, path and query all survive: the engine does the stremio:// ->
    // https:// rewrite itself, on the whole string.
    expect(screenUrl(tester), torrentio);
    expect(detailsActions(core), [
      CoreActions.loadAddonDetails(torrentio).toJson(),
    ]);
  });

  testWidgets('the link the app was launched with opens the details screen', (
    tester,
  ) async {
    final core = fakeCore();
    await pumpApp(tester, core, initial: cinemeta);
    await tester.pumpAndSettle();

    expect(find.byType(AddonDetailsScreen), findsOneWidget);
    expect(screenUrl(tester), cinemeta);
  });

  testWidgets('a link never installs the addon', (tester) async {
    final core = fakeCore();
    final links = await pumpApp(tester, core);

    links.send(cinemeta);
    await tester.pumpAndSettle();

    // Landing on the screen is the whole of it; installing stays a press.
    expect(
      core.dispatched.where(
        (action) => action.action['args']?['action'] == 'InstallAddon',
      ),
      isEmpty,
    );
    expect(find.widgetWithText(FilledButton, 'Install'), findsOneWidget);
  });

  testWidgets('a link with no host is dropped', (tester) async {
    final core = fakeCore();
    final links = await pumpApp(tester, core);

    links.send('stremio:///addons');
    await tester.pumpAndSettle();

    expect(find.byType(AddonDetailsScreen), findsNothing);
    expect(detailsActions(core), isEmpty);
  });

  testWidgets('a second link replaces the details screen instead of '
      'stacking another over the same field', (tester) async {
    final core = fakeCore();
    final links = await pumpApp(tester, core);

    links.send(cinemeta);
    await tester.pumpAndSettle();
    links.send(torrentio);
    await tester.pumpAndSettle();

    // One screen in the whole tree, offstage routes included: two of them
    // would fight over `addon_details` and the one underneath would render
    // the other's addon.
    expect(
      find.byType(AddonDetailsScreen, skipOffstage: false),
      findsOneWidget,
    );
    expect(screenUrl(tester), torrentio);
    // The replacement claims the field before the replaced screen goes, so
    // the screen that is up is not left rendering an unloaded field: no
    // Unload came after the second Load.
    expect(detailsActions(core), [
      CoreActions.loadAddonDetails(cinemeta).toJson(),
      CoreActions.loadAddonDetails(torrentio).toJson(),
    ]);
  });

  testWidgets('the same link twice changes nothing', (tester) async {
    final core = fakeCore();
    final links = await pumpApp(tester, core);

    links.send(cinemeta);
    await tester.pumpAndSettle();
    links.send(cinemeta);
    await tester.pumpAndSettle();

    expect(
      find.byType(AddonDetailsScreen, skipOffstage: false),
      findsOneWidget,
    );
    expect(detailsActions(core), hasLength(1));
  });

  testWidgets('an unavailable link platform leaves the app alone', (
    tester,
  ) async {
    final core = fakeCore();
    final links = await pumpApp(tester, core);

    links.fail(Exception('no implementation'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AddonDetailsScreen), findsNothing);
  });

  testWidgets('the subscription is cancelled with the app', (tester) async {
    final core = fakeCore();
    final links = await pumpApp(tester, core);
    expect(links.isListenedTo, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    expect(links.isListenedTo, isFalse);
  });
}
