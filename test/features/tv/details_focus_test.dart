import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/tv_episode_row.dart';
import 'package:xtremio/features/details/tv_meta_header.dart';
import 'package:xtremio/features/details/tv_source_row.dart';
import 'package:xtremio/features/downloads/download_labels.dart';
import 'package:xtremio/features/downloads/downloads_screen.dart';
import 'package:xtremio/features/downloads/remove_download_dialog.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/download_badge.dart';
import 'package:xtremio/widgets/focusable_tile.dart';
import 'package:xtremio/widgets/remote_press.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_downloads_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_prefs_client.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

const seriesId = 'tt0903747';
const pilotId = '$seriesId:1:1';

/// A Torrentio-style stream group for the selected episode, to graft onto
/// the series fixture (the default addons have no torrents for it).
Map<String, dynamic> torrentGroup(String videoId) => {
  'request': {
    'base': 'https://torrentio.example/manifest.json',
    'path': {
      'resource': 'stream',
      'type': 'series',
      'id': videoId,
      'extra': <Object>[],
    },
  },
  'content': {
    'type': 'Ready',
    'content': [
      {
        'infoHash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'fileIdx': 3,
        'name': 'Torrentio\n1080p',
        'description': 'Breaking.Bad.S01E01.1080p.mkv\n👤 42 💾 1.51 GB',
        'behaviorHints': {'filename': 'Breaking.Bad.S01E01.1080p.mkv'},
      },
    ],
  },
};

/// The series episode fixture (S1E1 selected and watched) with a playable
/// torrent for the pilot.
Map<String, dynamic> seriesWithTorrent() {
  final fixture = loadSeriesEpisodeMetaDetailsFixture();
  (fixture['streams'] as List<dynamic>).add(torrentGroup(pilotId));
  return fixture;
}

Widget harness(
  FakeCoreClient core, {
  String type = 'movie',
  String id = 'tt0063350',
  String? videoId,
  DeviceProfile device = tv,
  DownloadsClient? downloads,
  AppPrefs? prefs,
}) {
  Widget screen = PrefsScope(
    prefs: prefs ?? AppPrefs.inMemory(),
    child: PlaybackScope(
      createEngine: FakePlaybackEngine.new,
      torrentStats: FakeTorrentStatsClient(),
      child: MaterialApp(
        home: MetaDetailsScreen(type: type, id: id, videoId: videoId),
      ),
    ),
  );
  if (downloads != null) {
    screen = DownloadsScope(client: downloads, child: screen);
  }
  return DeviceScope(
    profile: device,
    child: CoreScope(client: core, child: screen),
  );
}

/// Two addons whose streams a remote has to walk in sorted order once the
/// list is flat: alpha answers with its worst release first.
List<Map<String, dynamic>> twoTorrentAddons() => [
  for (final (base, streams) in [
    (
      'https://alpha.example/manifest.json',
      [
        {
          'infoHash': 'a' * 40,
          'name': 'Alpha 720p',
          'description': '💾 900 MB',
        },
        {
          'infoHash': 'b' * 40,
          'name': 'Alpha 2160p',
          'description': '💾 20 GB',
        },
      ],
    ),
    (
      'https://beta.example/manifest.json',
      [
        {'infoHash': 'c' * 40, 'name': 'Beta 1080p', 'description': '👤 100'},
      ],
    ),
  ])
    {
      'request': {
        'base': base,
        'path': {
          'resource': 'stream',
          'type': 'movie',
          'id': 'tt0063350',
          'extra': <Object>[],
        },
      },
      'content': {'type': 'Ready', 'content': streams},
    },
];

Rect focusedRect() => FocusManager.instance.primaryFocus!.rect;

/// Every `Ctx` and `MetaDetails` action dispatched so far (never the
/// screen's own `Load`s), by its inner `action` name.
List<String> innerActions(FakeCoreClient core) => [
  for (final action in core.dispatched)
    if (action.action['action'] case 'Ctx' || 'MetaDetails')
      (action.action['args'] as Map<String, dynamic>)['action'] as String,
];

Object? innerArgs(CoreAction action) =>
    (action.action['args'] as Map<String, dynamic>)['args'];

/// The style the group card named [label] draws its own label in: what
/// says a card is the chosen one, beyond the colour of it.
TextStyle groupLabelStyle(WidgetTester tester, String label) => tester
    .widget<Text>(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is TvSourceGroupCard && w.group.label == label,
        ),
        matching: find.text(label),
      ),
    )
    .style!;

/// The name of the episode card holding primary focus.
String? focusedEpisodeTitle() {
  final card = FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<TvEpisodeCard>();
  return card == null ? null : TvEpisodeCard.title(card.video);
}

/// The screen is one column of rows now, and the remote starts at the
/// bottom of it, on the sources: [up] presses from there reach [T], an
/// episode card or a season pill on the way to the header.
Future<void> stepUpTo<T extends Widget>(
  WidgetTester tester, {
  int limit = 10,
}) async {
  for (var i = 0; i < limit && !focusIn<T>(); i++) {
    await press(tester, LogicalKeyboardKey.arrowUp);
  }
  expect(focusIn<T>(), isTrue);
}

/// Presses up until the remote is on a season pill.
///
/// The pills are chips, and so are the heading's two rows now -- the
/// layout pair and the order chips -- so `stepUpTo<ChoiceChip>` stops at
/// whichever comes first from below, which is never the pills. The labels
/// are what tell them apart.
Future<void> stepUpToPills(WidgetTester tester, {int limit = 8}) async {
  final heading = {
    kStreamsSectionedLabel,
    kStreamsGroupedLabel,
    for (final order in StreamOrder.values) order.label,
  };
  bool onPill() =>
      focusIn<ChoiceChip>() && !heading.contains(focusedLabel(tester));
  for (var i = 0; i < limit && !onPill(); i++) {
    await press(tester, LogicalKeyboardKey.arrowUp);
  }
  expect(onPill(), isTrue, reason: 'the remote reached the season pills');
}

/// The same walk the other way, for coming back down to the sources.
Future<void> stepDownTo<T extends Widget>(
  WidgetTester tester, {
  int limit = 10,
}) async {
  for (var i = 0; i < limit && !focusIn<T>(); i++) {
    await press(tester, LogicalKeyboardKey.arrowDown);
  }
  expect(focusIn<T>(), isTrue);
}

/// Walks the group row to [group], opens it, and steps down and along the
/// row it opened until the card named [source] holds the remote.
Future<void> openSource(
  WidgetTester tester,
  String group,
  String source, {
  int limit = 8,
}) async {
  for (var i = 0; i < limit && focusedLabel(tester) != group; i++) {
    await press(tester, LogicalKeyboardKey.arrowRight);
  }
  expect(focusedLabel(tester), group, reason: 'the group row reached $group');
  await press(tester, LogicalKeyboardKey.select);
  await press(tester, LogicalKeyboardKey.arrowDown);
  for (var i = 0; i < limit && focusedLabel(tester) != source; i++) {
    await press(tester, LogicalKeyboardKey.arrowRight);
  }
  expect(focusedLabel(tester), source);
  expect(focusIn<TvSourceCard>(), isTrue);
}

/// Presses up until the control tooltipped [tooltip] has focus: what is
/// between the top stream and the header's controls is the list's own
/// business (a section header, the order chips) and not this test's.
Future<void> pressUpToTooltip(
  WidgetTester tester,
  String tooltip, {
  int limit = 8,
}) async {
  for (var i = 0; i < limit && focusedTooltip() != tooltip; i++) {
    await press(tester, LogicalKeyboardKey.arrowUp);
  }
  expect(focusedTooltip(), tooltip);
}

/// Sectioned is the sources list's default now, and every section starts
/// collapsed, which most of these tests have nothing to do with -- they
/// are about the info column, the bookmark, Tab order, downloads. Grouped
/// keeps them landing focus on an actual stream, the way they were
/// written to, rather than on a section header; the "sectioned sources"
/// group below is what tests the collapsed default itself.
Future<AppPrefs> groupedPrefs() async {
  final prefs = AppPrefs(client: FakePrefsClient({'streamsSectioned': false}));
  addTearDown(prefs.dispose);
  await prefs.load();
  return prefs;
}

/// Mounts Breaking Bad at the pilot on a TV, focus on the group card of
/// the addon that answered with its torrent.
Future<FakeCoreClient> mountSeries(WidgetTester tester) async {
  useScreen(tester, tvSize);
  final core = FakeCoreClient(
    state: {CoreField.metaDetails: seriesWithTorrent()},
  );
  await tester.pumpWidget(
    harness(
      core,
      type: 'series',
      id: seriesId,
      videoId: pilotId,
      prefs: await groupedPrefs(),
    ),
  );
  await tester.pumpAndSettle();
  expect(focusedLabel(tester), 'torrentio.example');
  return core;
}

void main() {
  group('movie', () {
    testWidgets('the sources are a row under the rest, not a pane beside '
        'them, and the remote starts on the first group', (tester) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      await tester.pumpWidget(harness(core, prefs: await groupedPrefs()));
      await tester.pumpAndSettle();

      // The whole screen is one column: the rows have the panel's width,
      // rather than 480 px of it on the right.
      final rows = tester.getRect(find.byType(TvSourceRows));
      expect(rows.left, lessThan(tvSize.width * 0.1));
      expect(rows.width, greaterThan(tvSize.width * 0.8));

      // One card per addon that answered, in the profile's order, and the
      // remote on the first of them -- not on a stream, which is a press
      // further in now. Its row is out, because the highlight is what says
      // which addon the screen is showing.
      expect(focusIn<TvSourceGroupCard>(), isTrue);
      expect(focusedLabel(tester), 'watchhub.strem.io');
      expect(find.byType(TvSourceCard), findsWidgets);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(tester), 'caching.stremio.net');
    });

    testWidgets('select on a source opens the player; with no downloads '
        'client above, a held select is still a tap', (tester) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture(),
          CoreField.player: loadPlayerFixture(),
        },
      );
      await tester.pumpWidget(harness(core, prefs: await groupedPrefs()));
      await tester.pumpAndSettle();

      // WatchHub's externals cannot play, so none of its cards takes the
      // remote at all; the public-domain torrent is the next group along.
      await openSource(tester, 'caching.stremio.net', '1080p');

      await hold(
        tester,
        LogicalKeyboardKey.select,
        RemotePress.holdDuration * 2,
      );
      expect(find.byType(PlayerScreen), findsOneWidget);
    });

    testWidgets('the bookmark is reachable and select toggles it', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final fixture = loadMetaDetailsFixture();
      final core = FakeCoreClient(state: {CoreField.metaDetails: fixture});
      await tester.pumpWidget(harness(core, prefs: await groupedPrefs()));
      await tester.pumpAndSettle();
      expect(MetaDetailsState.fromJson(fixture).isInLibrary, isFalse);

      final bookmark = find.byTooltip('Add to library');
      await pressUpToTooltip(tester, 'Add to library', limit: 10);
      expect(
        tester.getRect(bookmark).contains(focusedRect().center),
        isTrue,
        reason: 'the focused button is the bookmark',
      );

      await press(tester, LogicalKeyboardKey.select);
      expect(innerActions(core), ['AddToLibrary']);
    });

    testWidgets(
      'off a TV nothing autofocuses and there is no remote handling',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final core = FakeCoreClient(
          state: {CoreField.metaDetails: loadMetaDetailsFixture()},
        );
        await tester.pumpWidget(harness(core, device: DeviceProfile.fallback));
        await tester.pumpAndSettle();

        expect(focusedLabel(tester), isNull);
        expect(find.byType(RemotePress), findsNothing);
      },
    );
  });

  group('sectioned sources', () {
    /// The movie on a TV with the two torrent addons, listed in sections
    /// (the default). [open] names which resolution labels start expanded
    /// -- empty, the default, is every section collapsed -- unless [prefs]
    /// is given outright.
    Future<FakeCoreClient> mountSectioned(
      WidgetTester tester, {
      AppPrefs? prefs,
      Set<String> open = const {},
      DownloadsClient? downloads,
    }) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture()
            ..['streams'] = twoTorrentAddons(),
        },
      );
      final layout =
          prefs ??
          AppPrefs(
            client: FakePrefsClient({
              if (open.isNotEmpty) 'openStreamSections': open.toList(),
            }),
          );
      // Read before the first build, the way start-up does it, so the
      // first sources list a remote sees already reflects the stored
      // choice.
      await layout.load();
      await tester.pumpWidget(
        harness(core, prefs: layout, downloads: downloads),
      );
      await tester.pumpAndSettle();
      return core;
    }

    testWidgets('a rung is a card, and the row is walked sideways', (
      tester,
    ) async {
      await mountSectioned(tester);

      // The resolutions are what the remote starts on, and the one it
      // starts on is open: a highlight over a shut row says nothing about
      // anything.
      expect(focusIn<TvSourceGroupCard>(), isTrue);
      expect(focusedLabel(tester), '2160p');
      expect(find.text('Alpha 2160p'), findsOneWidget);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(tester), '1080p');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(tester), '720p');

      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(tester), '2160p');
      // Each of those steps opened the row for the card it landed on, so
      // what is under the remote now is this card's own sources.
      expect(
        tester
            .widgetList<TvSourceGroupCard>(find.byType(TvSourceGroupCard))
            .where((card) => card.chosen)
            .map((card) => card.group.label),
        ['2160p'],
      );
    });

    testWidgets('the sections a phone remembers open do not open a row here', (
      tester,
    ) async {
      // Which sections are open is a global preference on a phone, kept
      // across restarts; here exactly one row is open at a time, it is the
      // one the remote is standing on, and Back closes it. They share a
      // word and nothing else, so a stored 1080p must not be what is out:
      // the row that opens is the one the highlight is on.
      await mountSectioned(tester, open: {'1080p'});

      expect(focusedLabel(tester), '2160p');
      expect(find.text('Alpha 2160p'), findsOneWidget, reason: 'the focused');
      expect(find.text('Beta 1080p'), findsNothing, reason: 'the remembered');
    });

    testWidgets('walking onto a group opens it beneath the row, which stays '
        'put with the card marked by more than a colour', (tester) async {
      await mountSectioned(tester);
      expect(find.text('Beta 1080p'), findsNothing);

      // The highlight is the choice: the row under the remote is the row
      // for the card it is on, and no press was needed to say so.
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(tester), '1080p');
      expect(find.text('Beta 1080p'), findsOneWidget);

      // And select on the card that is already open leaves it open, rather
      // than toggling the row away under the remote -- and goes down into
      // it, since the landing already chose it.
      await press(tester, LogicalKeyboardKey.select);

      expect(find.text('Beta 1080p'), findsOneWidget);
      expect(focusedLabel(tester), 'Beta 1080p', reason: 'down into the row');
      // Every rung is still on the screen, and the chosen one says so.
      final cards = tester
          .widgetList<TvSourceGroupCard>(find.byType(TvSourceGroupCard))
          .toList();
      expect(cards.map((card) => card.group.label), ['2160p', '1080p', '720p']);
      expect(cards.map((card) => card.chosen), [false, true, false]);
      expect(groupLabelStyle(tester, '1080p').fontWeight, FontWeight.w700);
      expect(
        groupLabelStyle(tester, '2160p').fontWeight,
        isNot(FontWeight.w700),
      );
    });

    testWidgets('up from a source goes to the group that opened it, not to '
        'whatever is drawn above it', (tester) async {
      await mountSectioned(tester);
      // The third rung, so the card that opened the row is well to the
      // left of the sources it opened: a source card is half again as wide
      // as a group card, and by the second source the nearest card above
      // is a different group entirely.
      for (var i = 0; i < 4 && focusedLabel(tester) != '720p'; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusedLabel(tester), '720p');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<TvSourceCard>(), isTrue);

      await press(tester, LogicalKeyboardKey.arrowUp);

      expect(focusIn<TvSourceGroupCard>(), isTrue);
      expect(
        focusedLabel(tester),
        '720p',
        reason: 'the card the viewer came down through',
      );
    });

    testWidgets('and up from the group row reaches the order chips on a '
        'film, which has no episode above it', (tester) async {
      await mountSectioned(tester);
      expect(focusIn<TvSourceGroupCard>(), isTrue);

      await press(tester, LogicalKeyboardKey.arrowUp);

      expect(focusIn<ChoiceChip>(), isTrue);
    });

    testWidgets('and the heading is two rungs, so both its controls are '
        'walked through in either direction', (tester) async {
      // The toggle is drawn on the heading's own line and the chips below
      // it. One rung for the pair would mean arriving at whichever came
      // first and never reaching the other, which is the failure this
      // screen had before the ladder: a control on screen, marked, and
      // unreachable.
      await mountSectioned(tester);
      expect(focusIn<TvSourceGroupCard>(), isTrue);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(tester), StreamOrder.peersPerSize.label);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(tester), kStreamsSectionedLabel);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(
        focusedLabel(tester),
        StreamOrder.peersPerSize.label,
        reason: 'and back down',
      );
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<TvSourceGroupCard>(), isTrue);
    });

    testWidgets('another group is a sideways press away, and takes the '
        'second row with it', (tester) async {
      await mountSectioned(tester);
      expect(
        find.text('Alpha 2160p'),
        findsOneWidget,
        reason: 'open on arrival',
      );

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(tester), '1080p', reason: 'no press back first');

      expect(find.text('Beta 1080p'), findsOneWidget);
      expect(find.text('Alpha 2160p'), findsNothing);
    });

    testWidgets('Back puts the open row away before it leaves the screen', (
      tester,
    ) async {
      await mountSectioned(tester);
      // The card the remote starts on has its row out already, so the
      // press that goes down into it is the first one the viewer makes.
      expect(find.text('Alpha 2160p'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), 'Alpha 2160p');

      await systemBack(tester);

      expect(find.byType(TvSourceCard), findsNothing);
      expect(find.byType(MetaDetailsScreen), findsOneWidget);
      // The card the remote was on went with the row, and the ring lands
      // back on the one that opened it -- the enclosing scope's own memory
      // of what held focus before, which is all that stands between this
      // and a dead D-pad.
      expect(focusedLabel(tester), '2160p');
      expect(focusIn<TvSourceGroupCard>(), isTrue);
      // And it stays shut: the card the remote has just been handed back
      // is the one the press closed, so reopening it here would make Back
      // look like it did nothing at all.
      expect(find.byType(TvSourceCard), findsNothing);
    });

    testWidgets('the order chips take the D-pad, and select picks one', (
      tester,
    ) async {
      final stored = FakePrefsClient();
      final prefs = AppPrefs(client: stored);
      addTearDown(prefs.dispose);
      await mountSectioned(tester, prefs: prefs);

      // Up from the first group card: the chips that say what order the
      // sources inside a group are in -- shown whether or not one is open.
      await stepUpTo<ChoiceChip>(tester, limit: 4);

      // And along them, which is what makes all three reachable.
      for (
        var i = 0;
        i < 4 && focusedLabel(tester) != StreamOrder.largest.label;
        i++
      ) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusedLabel(tester), StreamOrder.largest.label);

      await press(tester, LogicalKeyboardKey.select);
      expect(prefs.streamsOrder, StreamOrder.largest);
      expect(stored.stored['streamsOrder'], 'largest');
      // Picked, and on the way to the sources it orders: select does what
      // down does after, as it does on every row where the choice is a step
      // on the way down.
      expect(
        focusIn<TvSourceGroupCard>(),
        isTrue,
        reason: 'select on a chip moves down to the groups',
      );
      expect(
        tester
            .widget<ChoiceChip>(
              find.widgetWithText(ChoiceChip, StreamOrder.largest.label),
            )
            .selected,
        isTrue,
      );
    });

    testWidgets('the remote reaches the layout chips, which say which one '
        'is on screen, and select picks the other', (tester) async {
      final stored = FakePrefsClient();
      final prefs = AppPrefs(client: stored);
      addTearDown(prefs.dispose);
      await mountSectioned(tester, prefs: prefs);

      // Sectioned is what is on screen, so that is the chip wearing the
      // selection when the remote arrives.
      for (
        var i = 0;
        i < 6 && focusedLabel(tester) != kStreamsSectionedLabel;
        i++
      ) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusedLabel(tester), kStreamsSectionedLabel);
      expect(
        tester
            .widget<ChoiceChip>(
              find.widgetWithText(ChoiceChip, kStreamsSectionedLabel),
            )
            .selected,
        isTrue,
      );

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(tester), kStreamsGroupedLabel);
      await press(tester, LogicalKeyboardKey.select);
      // Grouped has no order to choose, so the order chips went with the
      // press and the next row down is the groups.
      expect(
        focusIn<TvSourceGroupCard>(),
        isTrue,
        reason: 'select on a chip moves down, past the rung that went away',
      );
      expect(
        tester
            .widget<ChoiceChip>(
              find.widgetWithText(ChoiceChip, kStreamsGroupedLabel),
            )
            .selected,
        isTrue,
      );
      expect(stored.stored, {'streamsSectioned': false});
      // Grouped again: the group row is one card per addon now, and what
      // one of them opens is that addon's own ranking, left to right.
      expect(
        tester
            .widgetList<TvSourceGroupCard>(find.byType(TvSourceGroupCard))
            .map((card) => card.group.label),
        ['alpha.example', 'beta.example'],
      );
      await stepDownTo<TvSourceGroupCard>(tester);
      for (var i = 0; i < 4 && focusedLabel(tester) != 'alpha.example'; i++) {
        await press(tester, LogicalKeyboardKey.arrowLeft);
      }
      expect(focusedLabel(tester), 'alpha.example');
      await press(tester, LogicalKeyboardKey.select);
      expect(
        tester.getTopLeft(find.text('Alpha 720p')).dx,
        lessThan(tester.getTopLeft(find.text('Alpha 2160p')).dx),
      );
    });

    testWidgets('a held select on a source in an open group still '
        'downloads it', (tester) async {
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await mountSectioned(tester, downloads: downloads);
      await openSource(tester, '2160p', 'Alpha 2160p');

      await hold(
        tester,
        LogicalKeyboardKey.select,
        RemotePress.holdDuration * 2,
      );

      expect(downloads.added, hasLength(1));
      expect(downloads.added.single.stream.infoHash, 'b' * 40);
      expect(find.byType(PlayerScreen), findsNothing);
    });
  });

  group('series', () {
    testWidgets('up from the sources reaches the episode row; the menu key '
        'toggles one watched; right and select load the next', (tester) async {
      final core = await mountSeries(tester);
      final meta = MetaDetailsState.fromJson(seriesWithTorrent()).meta!;
      final season1 = meta.videosOfSeason(1);

      await stepUpTo<TvEpisodeCard>(tester);
      final episode = focusedEpisodeTitle();
      final video = season1.singleWhere((v) => v.title == episode);

      await press(tester, LogicalKeyboardKey.contextMenu);
      expect(innerActions(core), ['MarkVideoAsWatched']);
      final args = innerArgs(core.dispatched.last) as List<dynamic>;
      expect((args[0] as Map<String, dynamic>)['id'], video.id);
      expect(args[1], video.id != pilotId, reason: 'flips the state');

      // The episodes are a row now, so the next one is sideways.
      await press(tester, LogicalKeyboardKey.arrowRight);
      final next = focusedEpisodeTitle();
      final nextVideo = season1.singleWhere((v) => v.title == next);
      expect(season1.indexOf(nextVideo), season1.indexOf(video) + 1);

      await press(tester, LogicalKeyboardKey.select);
      final load = core.dispatched.last;
      expect(load.action['action'], 'Load');
      final loadArgs = innerArgs(load) as Map<String, dynamic>;
      expect(loadArgs['streamPath']['id'], nextVideo.id);
    });

    testWidgets('a held select on an episode toggles watched too', (
      tester,
    ) async {
      final core = await mountSeries(tester);
      await stepUpTo<TvEpisodeCard>(tester);
      final loads = core.dispatched.length;

      await hold(
        tester,
        LogicalKeyboardKey.select,
        RemotePress.holdDuration * 2,
      );
      expect(innerActions(core), ['MarkVideoAsWatched']);
      expect(core.dispatched, hasLength(loads + 1), reason: 'no Load');
    });

    testWidgets('walking the season pills switches the season, with no '
        'press', (tester) async {
      await mountSeries(tester);
      final meta = MetaDetailsState.fromJson(seriesWithTorrent()).meta!;
      expect(find.text('Pilot'), findsOneWidget);

      await stepUpToPills(tester);
      // The row is one focus stop per season, walked with left and right.
      for (var i = 0; i < 8 && focusedLabel(tester) != '2'; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusedLabel(tester), '2');
      expect(focusIn<ChoiceChip>(), isTrue);

      // The episodes under it are already season 2's: the highlight is
      // what says which season the row below shows, and select is left to
      // mean the press that goes down into it.
      expect(find.text('Pilot'), findsNothing);
      expect(find.text(meta.videosOfSeason(2).first.title), findsOneWidget);

      await press(tester, LogicalKeyboardKey.select);
      expect(find.text(meta.videosOfSeason(2).first.title), findsOneWidget);
      expect(
        focusedEpisodeTitle(),
        meta.videosOfSeason(2).first.title,
        reason: 'select on a pill goes down into its episodes',
      );
    });

    testWidgets('the walk down from the title reaches the pills, and the '
        'episode row is where it was left', (tester) async {
      // Both halves of one report from the sofa. A press down from the
      // title stepped over the season pills -- they are narrow and packed
      // at the left, which is what directional focus punishes -- and the
      // episode row, arrived at sideways rather than through the ladder,
      // lost its memory of the card the viewer had been standing on,
      // because whatever the press landed on was written over it.
      await mountSeries(tester);
      await stepUpToPills(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowRight);
      final chosen = focusedEpisodeTitle();
      expect(chosen, isNotNull, reason: 'standing on an episode');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<ChoiceChip>(), isTrue, reason: 'the pills');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<TvMetaHeader>(), isTrue, reason: 'the title block');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<ChoiceChip>(), isTrue, reason: 'not stepped over');
      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(
        focusedEpisodeTitle(),
        chosen,
        reason: 'the card the remote left, not the one nearest the press',
      );
    });

    testWidgets('select on an episode goes where down goes', (tester) async {
      // Landing on an episode already loads its sources, so select had
      // nothing left to do and viewers pressed it and saw nothing happen.
      // It does what down does now: whichever of the heading's controls
      // is next, the same stop a press down reaches.
      await mountSeries(tester);
      await stepUpTo<TvEpisodeCard>(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      final episode = focusedEpisodeTitle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowDown);
      final below = focusedTooltip() ?? focusedLabel(tester);
      expect(focusIn<TvEpisodeCard>(), isFalse, reason: 'down left the row');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedEpisodeTitle(), episode, reason: 'back where it was');

      await press(tester, LogicalKeyboardKey.select);

      expect(focusIn<TvEpisodeCard>(), isFalse);
      expect(
        focusedTooltip() ?? focusedLabel(tester),
        below,
        reason: 'the stop down reaches',
      );
    });

    testWidgets('the walk up from the group row comes back to the episode '
        'these sources are for', (tester) async {
      await mountSeries(tester);
      // Walk the episode row first, so the episode the sources belong to
      // is not the one the row happens to start at.
      await stepUpTo<TvEpisodeCard>(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);
      final chosen = focusedEpisodeTitle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await stepDownTo<TvSourceGroupCard>(tester);
      // The heading's own controls are rungs between the two, so the walk
      // back up passes through them rather than over them -- and the
      // episode it arrives at is still the one that was left, which is
      // what a viewer means by going back up.
      await stepUpTo<TvEpisodeCard>(tester, limit: 4);

      expect(
        focusedEpisodeTitle(),
        chosen,
        reason: 'the card whose sources those were',
      );
    });

    testWidgets('an up press from the episode row reaches the pills, '
        'however narrow they are', (tester) async {
      // Two or three pills do not fill a television, and directional focus
      // prefers whatever overlaps the press horizontally -- so a card
      // further along the row would step over a short row of pills into
      // the header. The row hands the press up itself instead.
      await mountSeries(tester);
      await stepUpTo<TvEpisodeCard>(tester);
      for (var i = 0; i < 6 && focusedEpisodeTitle() != 'Pilot'; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }

      await press(tester, LogicalKeyboardKey.arrowUp);

      expect(focusIn<ChoiceChip>(), isTrue);
      expect(
        focusedLabel(tester),
        '1',
        reason: 'the pill of the season on screen, not the first of the row',
      );
    });

    testWidgets('the walk down from the pills stops at the sort and group-by '
        'controls on the way to the sources', (tester) async {
      // What the screen is a ladder *for*: these two lines of the heading
      // are between the episodes and the sources, and a press down that
      // went by distance stepped over one or both of them -- which on a
      // remote means they cannot be reached at all.
      await mountSeries(tester);
      for (var i = 0; i < 8 && focusedLabel(tester) != '1'; i++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusedLabel(tester), '1', reason: 'the pill of season 1');

      final stops = <String>[];
      for (var i = 0; i < 8 && !focusIn<TvSourceGroupCard>(); i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
        stops.add(focusedTooltip() ?? focusedLabel(tester) ?? 'nothing');
      }

      expect(focusIn<TvSourceGroupCard>(), isTrue, reason: 'it got there');
      // Grouped by addon here, which is the layout with no order to
      // choose and so no chips drawn: the toggle is the whole of the
      // heading's controls, and the walk stops on it.
      expect(
        stops.any(
          (stop) =>
              stop == kStreamsSectionedLabel || stop == kStreamsGroupedLabel,
        ),
        isTrue,
        reason: 'the layout chips are a stop on the way down',
      );
    });

    testWidgets('the sources follow the episode the remote stops on, and '
        'not the ones it passes over', (tester) async {
      final core = await mountSeries(tester);
      final meta = MetaDetailsState.fromJson(seriesWithTorrent()).meta!;
      final season1 = meta.videosOfSeason(1);
      await stepUpTo<TvEpisodeCard>(tester);

      // Raw presses: `press` settles, and settling runs the clock past the
      // wait this test is about.
      final before = innerActions(core).length;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        innerActions(core).length,
        before,
        reason: 'walking through a card asks no addon anything',
      );

      final stopped = focusedEpisodeTitle();
      final video = season1.singleWhere((v) => v.title == stopped);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final load = core.dispatched.last;
      expect(load.action['action'], 'Load');
      expect(
        (innerArgs(load) as Map<String, dynamic>)['streamPath']['id'],
        video.id,
        reason: 'the sources are the ones of the card it came to rest on',
      );
    });

    testWidgets('a focused pill wears the same indicator the posters do', (
      tester,
    ) async {
      // The row must not grow a highlight of its own: a chip's built-in
      // one is a tint, which is the cue a bright room takes away first.
      await mountSeries(tester);
      await stepUpToPills(tester);

      final onPill = FocusManager.instance.primaryFocus!.context!
          .findAncestorWidgetOfExactType<FocusHighlight>();
      expect(onPill?.focused, isTrue);
      expect(
        tester
            .widgetList<FocusHighlight>(find.byType(FocusHighlight))
            .where((highlight) => highlight.focused),
        hasLength(1),
        reason: 'only the pill the remote is on is marked',
      );
    });

    testWidgets('every pill of a long series is built, so the D-pad walks '
        'the whole row', (tester) async {
      useScreen(tester, tvSize);
      final fixture = seriesWithTorrent();
      final videos =
          fixture['metaItems'][0]['content']['content']['videos']
              as List<dynamic>;
      // Twenty seasons: several rows' worth at 1280 px.
      for (var season = 6; season <= 20; season++) {
        videos.add({
          ...videos.first as Map<String, dynamic>,
          'id': '$seriesId:$season:1',
          'title': 'Season $season opener',
          'season': season,
          'episode': 1,
        });
      }
      final core = FakeCoreClient(state: {CoreField.metaDetails: fixture});
      // Grouped, so the only chips between the remote and the pills are
      // the pills: the sectioned layout's order chips are chips too.
      await tester.pumpWidget(
        harness(
          core,
          type: 'series',
          id: seriesId,
          videoId: pilotId,
          prefs: await groupedPrefs(),
        ),
      );
      await tester.pumpAndSettle();

      await stepUpToPills(tester);
      for (var i = 0; i < 30 && focusedLabel(tester) != '1'; i++) {
        await press(tester, LogicalKeyboardKey.arrowLeft);
      }
      expect(focusedLabel(tester), '1');

      // Right to the far end of the row. Directional focus only considers
      // widgets that have been built, so a lazily built row would stop the
      // D-pad at the last realised pill, halfway through the series.
      for (var i = 0; i < 30 && focusedLabel(tester) != 'Specials'; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focusedLabel(tester), 'Specials');

      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('Pilot'), findsNothing);
    });
  });

  group('downloads on a remote', () {
    /// The one torrent of the movie fixture.
    const movieHash = '11ea02584fa6351956f35671962ab46354d99060';
    const movieId = 'tt0063350';

    /// A registry holding the movie, downloaded and whole.
    DownloadsRegistry downloaded() {
      final entry = DownloadView({
        'metaId': movieId,
        'videoId': movieId,
        'name': 'Night of the Living Dead',
        'stream': {'infoHash': movieHash, 'fileIdx': 0},
        'infoHash': movieHash,
        'fileIdx': 0,
        'size': 1000,
        'downloaded': 1000,
        'state': 'complete',
        'path': '/downloads/night.mkv',
      });
      return DownloadsRegistry(items: {entry.key: entry});
    }

    testWidgets('holding select on a downloaded stream asks to remove it', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient(registry: downloaded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(core, downloads: downloads, prefs: await groupedPrefs()),
      );
      await tester.pumpAndSettle();

      // The card says the file is on the device, and says it passively:
      // a button drawn inside a focusable thing cannot be reached by a
      // remote at all, which is why the hold below is the whole gesture.
      await openSource(tester, 'caching.stremio.net', '1080p');
      final badge = tester.widget<DownloadBadge>(
        find.descendant(
          of: find.byType(TvSourceCard),
          matching: find.byType(DownloadBadge),
        ),
      );
      expect(badge.onDelete, isNull);

      await hold(tester, LogicalKeyboardKey.select, RemotePress.holdDuration);

      expect(find.byType(PlayerScreen), findsNothing, reason: 'not a tap');
      expect(find.text('Delete Night of the Living Dead?'), findsOneWidget);
      await tester.tap(find.text(RemoveDownloadDialog.deleteLabel));
      await tester.pumpAndSettle();
      expect(downloads.removed, [
        (key: '$movieId:$movieId', deleteFiles: true),
      ]);
    });

    testWidgets('holding select on a stream whose pieces are gone downloads '
        'it again', (tester) async {
      // The remote's one option on a source card is whatever the button
      // beside the play arrow would do, and on a row the boot marked gone
      // that is "have this file again". Without it a television has no way
      // at all to recover a download the moved root took with it: the
      // button inside the card cannot be focused.
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final gone = DownloadView({
        'metaId': movieId,
        'videoId': movieId,
        'name': 'Night of the Living Dead',
        'stream': {'infoHash': movieHash, 'fileIdx': 0},
        'infoHash': movieHash,
        'fileIdx': 0,
        'size': 1000,
        'downloaded': 0,
        'state': 'gone',
        'error': 'the downloaded data is not on this device any more',
      });
      final downloads = FakeDownloadsClient(
        registry: DownloadsRegistry(items: {gone.key: gone}),
      );
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(core, downloads: downloads, prefs: await groupedPrefs()),
      );
      await tester.pumpAndSettle();

      await openSource(tester, 'caching.stremio.net', '1080p');
      await hold(tester, LogicalKeyboardKey.select, RemotePress.holdDuration);

      expect(find.byType(PlayerScreen), findsNothing, reason: 'not a tap');
      expect(downloads.added.single.stream.infoHash, movieHash);
    });

    testWidgets('holding select on a stream that is not kept downloads it', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient();
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(core, downloads: downloads, prefs: await groupedPrefs()),
      );
      await tester.pumpAndSettle();

      await openSource(tester, 'caching.stremio.net', '1080p');
      await hold(tester, LogicalKeyboardKey.select, RemotePress.holdDuration);

      expect(find.byType(PlayerScreen), findsNothing, reason: 'not a tap');
      expect(downloads.added.single.stream.infoHash, movieHash);
    });

    testWidgets('a tap still plays what is kept, rather than removing it', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {
          CoreField.metaDetails: loadMetaDetailsFixture(),
          CoreField.player: loadPlayerFixture(),
        },
      );
      final downloads = FakeDownloadsClient(registry: downloaded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(core, downloads: downloads, prefs: await groupedPrefs()),
      );
      await tester.pumpAndSettle();

      await openSource(tester, 'caching.stremio.net', '1080p');
      await press(tester, LogicalKeyboardKey.select);

      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(downloads.removed, isEmpty);
    });

    testWidgets('the app bar way to the downloads list takes the D-pad', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final core = FakeCoreClient(
        state: {CoreField.metaDetails: loadMetaDetailsFixture()},
      );
      final downloads = FakeDownloadsClient(registry: downloaded());
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        harness(core, downloads: downloads, prefs: await groupedPrefs()),
      );
      await tester.pumpAndSettle();

      await pressUpToTooltip(tester, kDownloadsScreenTooltip, limit: 10);

      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(DownloadsScreen), findsOneWidget);
    });
  });
}
