import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addon_health.dart';
import 'package:xtremio/features/addons/addon_health_client.dart';
import 'package:xtremio/features/addons/addon_health_view.dart';
import 'package:xtremio/features/addons/addon_tile.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
import 'package:xtremio/shell/external_link.dart';

import '../../support/fake_addon_health_client.dart';
import '../../support/fake_core_client.dart';
import '../../support/fake_link_opener.dart';
import '../../support/fixtures.dart';

void main() {
  // The addons the default profile ships with, which is also the cast this
  // screen's verdicts are about.
  const cinemeta = 'https://v3-cinemeta.strem.io/manifest.json';
  const youtube = 'https://v3-channels.strem.io/manifest.json';
  const watchhub = 'https://watchhub.strem.io/manifest.json';
  const publicDomain =
      'https://caching.stremio.net/publicdomainmovies.now.sh/manifest.json';

  final now = DateTime.now().toUtc();

  AddonHealthRecord record({
    double ok = 0,
    double empty = 0,
    double fail = 0,
    Duration? workedAgo,
  }) => AddonHealthRecord(
    ok: ok,
    empty: empty,
    fail: fail,
    lastOk: workedAgo == null ? null : now.subtract(workedAgo),
    updated: now,
  );

  /// A record for every addon the verdicts have something to say about:
  /// WatchHub unreachable -- it answered once, a month ago, which is what
  /// keeps it out of the never-answered bucket -- Public Domain Movies
  /// answering with nothing, YouTube working, Cinemeta (protected) with a
  /// record it is never labelled for, and OpenSubtitles with none at all.
  Map<String, Map<AddonResourceKind, AddonHealthRecord>> records() => {
    addonHealthKey(watchhub): {
      AddonResourceKind.stream: record(
        ok: 1,
        fail: 12,
        workedAgo: const Duration(days: 30),
      ),
    },
    addonHealthKey(publicDomain): {
      AddonResourceKind.catalog: record(empty: 40),
      AddonResourceKind.stream: record(empty: 40),
    },
    addonHealthKey(youtube): {
      AddonResourceKind.catalog: record(
        ok: 20,
        empty: 10,
        workedAgo: const Duration(days: 3),
      ),
    },
    addonHealthKey(cinemeta): {AddonResourceKind.catalog: record(fail: 30)},
  };

  Widget harness(FakeCoreClient core, {AddonHealthClient? health}) {
    const screen = MaterialApp(home: AddonsScreen());
    return CoreScope(
      client: core,
      child: ExternalLinkScope(
        opener: FakeLinkOpener(),
        child: health == null
            ? screen
            : AddonHealthScope(client: health, child: screen),
      ),
    );
  }

  FakeCoreClient fakeCore() => FakeCoreClient(
    state: {
      CoreField.installedAddons: loadInstalledAddonsFixture(),
      CoreField.remoteAddons: loadRemoteAddonsFixture(),
      CoreField.addonDetails: loadAddonDetailsFixture(),
      CoreField.ctx: loadCtxLoggedOutFixture(),
    },
  );

  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<FakeAddonHealthClient> pumpScreen(
    WidgetTester tester, {
    FakeAddonHealthClient? health,
  }) async {
    useTallScreen(tester);
    final client = health ?? FakeAddonHealthClient(addons: records());
    await tester.pumpWidget(harness(fakeCore(), health: client));
    await tester.pumpAndSettle();
    return client;
  }

  /// The status line on the tile named [name].
  Finder chipOf(String name) => find.descendant(
    of: find.ancestor(of: find.text(name), matching: find.byType(AddonTile)),
    matching: find.byType(AddonHealthChip),
  );

  Future<void> openMenuOf(WidgetTester tester, String name) async {
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text(name),
          matching: find.byType(AddonTile),
        ),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Puts the list in [sort] through the menu the screen offers.
  Future<void> chooseSort(WidgetTester tester, AddonHealthSort sort) async {
    await tester.tap(find.byType(DropdownMenu<int>));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(MenuItemButton),
            matching: find.text(sort.label),
          )
          .last,
    );
    await tester.pumpAndSettle();
  }

  /// The installed addons in the order the list draws them.
  List<String> listedNames(WidgetTester tester) => [
    for (final tile in tester.widgetList<AddonTile>(find.byType(AddonTile)))
      tile.addon.manifest.name,
  ];

  testWidgets('each installed addon says how it has been answering', (
    tester,
  ) async {
    await pumpScreen(tester);

    // Failing every time and never having worked is unreachable...
    expect(find.text('Often unreachable'), findsOneWidget);
    expect(chipOf('WatchHub'), findsOneWidget);
    expect(
      tester.widget<AddonHealthChip>(chipOf('WatchHub')).health.verdict(now),
      AddonHealthVerdict.broken,
    );

    // ...while answering, every time, with nothing is not. This is the
    // whole reason the record has three buckets and not two: a
    // public-domain catalog legitimately has nothing for most titles.
    expect(
      tester
          .widget<AddonHealthChip>(chipOf('Public Domain Movies'))
          .health
          .verdict(now),
      AddonHealthVerdict.useless,
    );
    expect(find.text('Rarely has anything'), findsOneWidget);

    // A working addon says how often what it is asked for has something.
    expect(find.text('Working · catalogs 67%'), findsOneWidget);

    // Nothing asked of it, nothing said about it.
    expect(chipOf('OpenSubtitles v3'), findsOneWidget);
    expect(find.text('Not used yet'), findsOneWidget);
  });

  testWidgets('a protected addon is never labelled, whatever its record', (
    tester,
  ) async {
    await pumpScreen(tester);

    // Cinemeta's record in this fixture would read as unreachable on any
    // other addon. It cannot be uninstalled, so the verdict would be advice
    // nobody can take -- and the local addon's answers are this app's own
    // stub rather than anything on the network.
    expect(chipOf('Cinemeta'), findsNothing);
    expect(chipOf('Local Files (without catalog support)'), findsNothing);
    expect(find.byType(AddonHealthChip), findsNWidgets(4));
  });

  testWidgets('every verdict says there is something behind it', (
    tester,
  ) async {
    await pumpScreen(tester);

    // One chevron per chip, and each drawn in its verdict's own colour, so
    // the invitation reads as part of the verdict rather than as a control
    // parked next to it.
    final chevrons = find.descendant(
      of: find.byType(AddonHealthChip),
      matching: find.byIcon(AddonHealthChip.affordance),
    );
    expect(chevrons, findsNWidgets(4));
    final theme = Theme.of(tester.element(find.byType(AddonsScreen)));
    expect(
      tester
          .widget<Icon>(
            find
                .descendant(
                  of: chipOf('WatchHub'),
                  matching: find.byIcon(AddonHealthChip.affordance),
                )
                .first,
          )
          .color,
      AddonHealthChip.colorOf(AddonHealthVerdict.broken, theme),
    );
  });

  testWidgets('the evidence behind a verdict is one tap away', (tester) async {
    await pumpScreen(tester);
    await tester.tap(chipOf('Public Domain Movies'));
    await tester.pumpAndSettle();

    expect(find.byType(AddonHealthEvidence), findsOneWidget);
    expect(find.text(AddonHealthEvidence.neverWorked), findsOneWidget);
    expect(
      find.text('catalogs · 0 answered · 40 empty · 0 failed'),
      findsOneWidget,
    );
    expect(
      find.text('streams · 0 answered · 40 empty · 0 failed'),
      findsOneWidget,
    );

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // A kind the manifest declares that nothing has ever asked for reads as
    // unasked, not as three zeroes: the app only ever sees what a screen
    // actually requested.
    await tester.tap(chipOf('YouTube'));
    await tester.pumpAndSettle();
    expect(find.text('Last worked 3 days ago'), findsOneWidget);
    expect(
      find.text('catalogs · 20 answered · 10 empty · 0 failed'),
      findsOneWidget,
    );
    expect(
      find.text('details · ${AddonHealthEvidence.notAsked}'),
      findsOneWidget,
    );
  });

  testWidgets('the list can be ordered least useful first', (tester) async {
    await pumpScreen(tester);
    final profileOrder = listedNames(tester);
    expect(profileOrder.first, 'Cinemeta');

    await chooseSort(tester, AddonHealthSort.leastUsefulFirst);

    // Unreachable, then rarely-has-anything, then the ones nothing is known
    // about, then the working one; a protected addon sorts last, because it
    // is never a decision to make.
    expect(listedNames(tester), [
      'WatchHub',
      'Public Domain Movies',
      'OpenSubtitles v3',
      'YouTube',
      'Cinemeta',
      'Local Files (without catalog support)',
    ]);

    // And back, without losing anything.
    await chooseSort(tester, AddonHealthSort.profileOrder);
    expect(listedNames(tester), profileOrder);
  });

  testWidgets('the evidence says what was actually measured', (tester) async {
    // WatchHub has failed every request it was ever given, which is the
    // strongest thing this app says about an addon -- and the weakest
    // possible claim about the addon itself.
    await pumpScreen(
      tester,
      health: FakeAddonHealthClient(
        addons: {
          ...records(),
          addonHealthKey(watchhub): {
            AddonResourceKind.stream: record(fail: 12),
          },
        },
      ),
    );
    await tester.tap(chipOf('WatchHub'));
    await tester.pumpAndSettle();

    expect(find.text(AddonHealthEvidence.neverAnsweredHere), findsOneWidget);
    expect(find.text(AddonHealthEvidence.neverWorked), findsOneWidget);
    expect(
      find.text('streams · 0 answered · 0 empty · 12 failed'),
      findsOneWidget,
    );

    // It is said about that addon and no other: the one that is merely
    // unreliable answered once, and the dialog behind it must not claim
    // otherwise.
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(chipOf('Public Domain Movies'));
    await tester.pumpAndSettle();
    expect(find.text(AddonHealthEvidence.neverAnsweredHere), findsNothing);
  });

  testWidgets('the evidence does not claim a record this row can reset', (
    tester,
  ) async {
    // The sentence behind *Never answered here* is what bounds the app's
    // strongest verdict, so it has to be true of every record it is shown
    // over -- including one the viewer has already wiped.
    await pumpScreen(
      tester,
      health: FakeAddonHealthClient(
        addons: {
          ...records(),
          addonHealthKey(watchhub): {
            AddonResourceKind.stream: record(fail: 12),
          },
        },
      ),
    );
    await tester.tap(chipOf('WatchHub'));
    await tester.pumpAndSettle();
    final claim = tester
        .widget<Text>(find.text(AddonHealthEvidence.neverAnsweredHere))
        .data!;
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Because the very row the verdict is drawn under offers to delete the
    // record (`Table::forget` drops the addon's key outright, and the next
    // failed request starts a fresh one), a record does not begin at
    // installation for any addon this menu item has been used on.
    // So the sentence has to name both places a record can begin, not just
    // the install.
    await openMenuOf(tester, 'WatchHub');
    expect(find.text('Forget this addon\'s history'), findsOneWidget);
    expect(claim, contains('installed'));
    expect(
      claim,
      contains('forgotten'),
      reason: 'the record does not survive the forget this row offers',
    );
  });

  testWidgets('the one that never answered sorts above the unreliable one', (
    tester,
  ) async {
    // YouTube answered once, a month ago, and has failed ever since;
    // WatchHub has never answered at all. YouTube is ahead of WatchHub in
    // the profile, so the order below is the rank and not the fixture.
    await pumpScreen(
      tester,
      health: FakeAddonHealthClient(
        addons: {
          ...records(),
          addonHealthKey(youtube): {
            AddonResourceKind.catalog: record(
              ok: 1,
              fail: 12,
              workedAgo: const Duration(days: 30),
            ),
          },
          addonHealthKey(watchhub): {
            AddonResourceKind.stream: record(fail: 12),
          },
        },
      ),
    );
    expect(
      listedNames(tester).indexOf('YouTube'),
      lessThan(listedNames(tester).indexOf('WatchHub')),
      reason: 'the profile order this sort has to overturn',
    );

    // The chip says the stronger thing, and says it about the addon that
    // has failed every time it was ever asked.
    expect(
      tester.widget<AddonHealthChip>(chipOf('WatchHub')).health.verdict(now),
      AddonHealthVerdict.neverAnswered,
    );
    expect(find.text('Never answered here'), findsOneWidget);
    expect(find.text('Often unreachable'), findsOneWidget);

    await chooseSort(tester, AddonHealthSort.leastUsefulFirst);
    expect(listedNames(tester).take(2), ['WatchHub', 'YouTube']);
  });

  testWidgets('an addon\'s history can be forgotten, by its key alone', (
    tester,
  ) async {
    final health = await pumpScreen(tester);

    await openMenuOf(tester, 'WatchHub');
    await tester.tap(find.text('Forget this addon\'s history'));
    await tester.pumpAndSettle();

    // What crosses is the record's key. The transport URL never leaves the
    // profile -- a manifest URL can carry a debrid API key.
    expect(health.forgotten, [addonHealthKey(watchhub)]);
    expect(health.forgotten.single, isNot(contains('manifest.json')));
    expect(health.forgotten.single, isNot(contains('https')));
    expect(find.text('Forgot how WatchHub has been answering'), findsOneWidget);

    // The verdict is gone with the record, and the addon is still
    // installed.
    expect(find.text('Often unreachable'), findsNothing);
    expect(find.text('WatchHub'), findsOneWidget);

    // With nothing recorded there is nothing left to forget.
    await openMenuOf(tester, 'WatchHub');
    expect(find.text('Forget this addon\'s history'), findsNothing);
  });

  testWidgets('a forget that threw is not reported as one', (tester) async {
    final health = await pumpScreen(tester);
    // The core going away between the read and the tap.
    health.forgetFails = true;

    await openMenuOf(tester, 'WatchHub');
    await tester.tap(find.text('Forget this addon\'s history'));
    await tester.pumpAndSettle();

    // Saying "forgot" about a record that is still there is a claim about
    // something the app did not do, and the verdict still on the tile
    // contradicts it on the same screen.
    expect(find.text('Forgot how WatchHub has been answering'), findsNothing);
    expect(
      find.text('Could not forget how WatchHub has been answering'),
      findsOneWidget,
    );
    expect(find.text('Often unreachable'), findsOneWidget);
  });

  testWidgets('a forget with nothing to drop says so too', (tester) async {
    final health = await pumpScreen(tester);
    // The record went out from under the screen -- evicted, or a table the
    // Rust side never finished loading. The menu item is still on the tile
    // the last read drew.
    health.addons.clear();

    await openMenuOf(tester, 'WatchHub');
    await tester.tap(find.text('Forget this addon\'s history'));
    await tester.pumpAndSettle();

    expect(health.forgotten, [addonHealthKey(watchhub)]);
    expect(find.text('Forgot how WatchHub has been answering'), findsNothing);
    expect(
      find.text('Could not forget how WatchHub has been answering'),
      findsOneWidget,
    );
  });

  testWidgets('a verdict adds no way at all to remove an addon', (
    tester,
  ) async {
    await pumpScreen(tester);

    // The unreachable one has exactly the menu it had before health
    // existed, plus Forget.
    await openMenuOf(tester, 'WatchHub');
    expect(find.text('Uninstall'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // And a protected addon still has neither, however bad its record.
    await openMenuOf(tester, 'Cinemeta');
    expect(find.text('Uninstall'), findsNothing);
    expect(find.text('Forget this addon\'s history'), findsNothing);
  });

  testWidgets('when nothing has answered at all, it says so', (tester) async {
    await pumpScreen(
      tester,
      health: FakeAddonHealthClient(addons: records(), everyAnswerFailed: true),
    );
    expect(find.byType(AddonConnectionBanner), findsOneWidget);

    // The verdicts are still shown: an all-failed sweep is recorded against
    // nobody, so the record the banner qualifies was never poisoned by it.
    expect(find.text('Often unreachable'), findsOneWidget);
  });

  testWidgets('with a healthy connection there is no banner', (tester) async {
    await pumpScreen(tester);
    expect(find.byType(AddonConnectionBanner), findsNothing);
  });

  testWidgets('with nothing to read the list simply says nothing', (
    tester,
  ) async {
    useTallScreen(tester);
    await tester.pumpWidget(harness(fakeCore()));
    await tester.pumpAndSettle();

    expect(find.byType(AddonHealthChip), findsNothing);
    expect(find.byType(DropdownMenu<int>), findsNothing, reason: 'no sort');
    expect(find.text('WatchHub'), findsOneWidget);

    await openMenuOf(tester, 'WatchHub');
    expect(find.text('Forget this addon\'s history'), findsNothing);
    expect(find.text('Uninstall'), findsOneWidget);
  });

  testWidgets('a record that cannot be read is not a broken screen', (
    tester,
  ) async {
    await pumpScreen(tester, health: FakeAddonHealthClient(failing: true));
    expect(find.byType(AddonHealthChip), findsNothing);
    expect(find.byType(AddonConnectionBanner), findsNothing);
    expect(find.text('WatchHub'), findsOneWidget);
  });
}
