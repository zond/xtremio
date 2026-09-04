import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/stream_facts.dart';
import 'package:xtremio/features/details/tv_source_row.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_prefs_client.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

const movieId = 'tt0063350';

/// One addon's stream group for the movie.
Map<String, dynamic> group(String host, List<Map<String, dynamic>> streams) => {
  'request': {
    'base': 'https://$host/manifest.json',
    'path': {
      'resource': 'stream',
      'type': 'movie',
      'id': movieId,
      'extra': <Object>[],
    },
  },
  'content': {'type': 'Ready', 'content': streams},
};

/// A torrent stream, named and described the way an addon writes them.
Map<String, dynamic> torrent(String hash, String name, String description) => {
  'infoHash': hash,
  'name': name,
  'description': description,
};

/// A hash that is unique to [seed] and forty hex characters long.
String hash(int seed) => seed.toRadixString(16).padLeft(40, '0');

/// The movie with [streams] instead of the recorded ones.
Map<String, dynamic> movieWith(List<Map<String, dynamic>> streams) =>
    loadMetaDetailsFixture()..['streams'] = streams;

/// [fixture] with its first addon's first stream recorded as the source it
/// was last played from.
Map<String, dynamic> withLastUsed(Map<String, dynamic> fixture) {
  final streams = fixture['streams'] as List<dynamic>;
  final first = streams.first as Map<String, dynamic>;
  fixture['lastUsedStream'] = {
    'request': first['request'],
    'content': {
      'type': 'Ready',
      'content': (first['content'] as Map<String, dynamic>)['content']![0],
    },
  };
  return fixture;
}

Widget harness(
  FakeCoreClient core, {
  DeviceProfile device = tv,
  required AppPrefs prefs,
}) => DeviceScope(
  profile: device,
  child: CoreScope(
    client: core,
    child: PrefsScope(
      prefs: prefs,
      child: PlaybackScope(
        createEngine: FakePlaybackEngine.new,
        torrentStats: FakeTorrentStatsClient(),
        child: const MaterialApp(
          home: MetaDetailsScreen(type: 'movie', id: movieId),
        ),
      ),
    ),
  ),
);

/// The layout preference as [sectioned] says, read before the first build
/// the way start-up does it.
Future<AppPrefs> prefsFor({required bool sectioned}) async {
  final prefs = AppPrefs(
    client: FakePrefsClient({'streamsSectioned': sectioned}),
  );
  addTearDown(prefs.dispose);
  await prefs.load();
  return prefs;
}

Future<void> mount(
  WidgetTester tester,
  Map<String, dynamic> fixture, {
  bool sectioned = false,
  DeviceProfile device = tv,
  Size size = tvSize,
  Map<CoreField, Map<String, dynamic>> also = const {},
}) async {
  useScreen(tester, size);
  await tester.pumpWidget(
    harness(
      FakeCoreClient(state: {CoreField.metaDetails: fixture, ...also}),
      device: device,
      prefs: await prefsFor(sectioned: sectioned),
    ),
  );
  await tester.pumpAndSettle();
}

/// The labels of the group row, left to right.
List<String> groupLabels(WidgetTester tester) => [
  for (final card in tester.widgetList<TvSourceGroupCard>(
    find.byType(TvSourceGroupCard),
  ))
    card.group.label,
];

/// The titles of the row of sources under it, left to right.
List<String> sourceTitles(WidgetTester tester) => [
  for (final card in tester.widgetList<TvSourceCard>(find.byType(TvSourceCard)))
    card.source.title,
];

/// Everything drawn inside the card titled [title].
Finder inSource(String title, Finder matching) => find.descendant(
  of: find.byWidgetPredicate(
    (w) => w is TvSourceCard && w.source.title == title,
  ),
  matching: matching,
);

void main() {
  testWidgets('the groups are the resolutions, and choosing one lists that '
      'rung and only that rung', (tester) async {
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p', '👤 20 💾 2 GB'),
          torrent(hash(2), 'Alpha 720p', '👤 30 💾 900 MB'),
        ]),
        group('beta.example', [
          torrent(hash(3), 'Beta 1080p', '👤 90 💾 2 GB'),
        ]),
      ]),
      sectioned: true,
    );

    expect(groupLabels(tester), ['1080p', '720p']);
    expect(sourceTitles(tester), isEmpty);

    await press(tester, LogicalKeyboardKey.select);
    // Both addons' 1080p releases, in the order the chips choose (peers
    // per megabyte: beta's ninety peers over the same two gigabytes).
    expect(sourceTitles(tester), ['Beta 1080p', 'Alpha 1080p']);
  });

  testWidgets('the groups are the addons when the preference says so, each '
      'holding that addon\'s own answers', (tester) async {
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p', '👤 20 💾 2 GB'),
          torrent(hash(2), 'Alpha 720p', '👤 30 💾 900 MB'),
        ]),
        group('beta.example', [
          torrent(hash(3), 'Beta 1080p', '👤 90 💾 2 GB'),
        ]),
      ]),
    );

    expect(groupLabels(tester), ['alpha.example', 'beta.example']);
    final card = tester.widget<TvSourceGroupCard>(
      find.byType(TvSourceGroupCard).first,
    );
    expect(card.group.summary, '2 sources');

    await press(tester, LogicalKeyboardKey.select);
    expect(sourceTitles(tester), ['Alpha 1080p', 'Alpha 720p']);
  });

  testWidgets('a source card says the release, what is known of it, which '
      'addon answered and who else offered it', (tester) async {
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p', '👤 42 💾 1.5 GB'),
        ]),
        group('beta.example', [
          torrent(hash(1), 'Beta 1080p', '👤 42 💾 1.5 GB'),
        ]),
      ]),
      sectioned: true,
    );
    await press(tester, LogicalKeyboardKey.select);

    // One release is one card, whichever addon it came from.
    expect(sourceTitles(tester), ['Alpha 1080p']);
    expect(inSource('Alpha 1080p', find.text('1080p')), findsOneWidget);
    expect(inSource('Alpha 1080p', find.text('1.5 GB')), findsOneWidget);
    expect(inSource('Alpha 1080p', find.text('42 seeders')), findsOneWidget);
    expect(
      inSource('Alpha 1080p', find.text('alpha.example')),
      findsOneWidget,
      reason: 'no heading above it any more',
    );
    expect(
      inSource('Alpha 1080p', find.text('Also from beta.example')),
      findsOneWidget,
    );
  });

  testWidgets('a source the player cannot open takes no press and no focus', (
    tester,
  ) async {
    // WatchHub's answers are `externalUrl`s: a card that could be focused
    // and then did nothing is worse than one the remote steps over.
    await mount(tester, loadMetaDetailsFixture());

    expect(groupLabels(tester).first, 'watchhub.strem.io');
    await press(tester, LogicalKeyboardKey.select);
    expect(sourceTitles(tester), isNotEmpty);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(
      focusIn<TvSourceCard>(),
      isFalse,
      reason: 'nothing in the row it opened can be reached',
    );
    // And the card says why, where the play arrow would have been.
    expect(
      inSource('Amazon Prime Video', find.text('External')),
      findsOneWidget,
    );
  });

  testWidgets('the last-used source is a card of its own above the groups, '
      'and where the remote starts', (tester) async {
    await mount(
      tester,
      withLastUsed(
        movieWith([
          group('alpha.example', [
            torrent(hash(1), 'Alpha 1080p', '👤 20 💾 2 GB'),
          ]),
        ]),
      ),
      also: {CoreField.player: loadPlayerFixture()},
    );

    expect(focusIn<TvSourceCard>(), isTrue);
    expect(focusedLabel(tester), kContinueWithLastSource);
    expect(
      tester.getTopLeft(find.text(kContinueWithLastSource)).dy,
      lessThan(tester.getTopLeft(find.text('alpha.example')).dy),
    );
    // It says which release it is, and it plays.
    expect(
      inSource(kContinueWithLastSource, find.text('Alpha 1080p')),
      findsOneWidget,
    );
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(PlayerScreen), findsOneWidget);
  });

  testWidgets('the D-pad reaches the last card of a group row far longer '
      'than fits', (tester) async {
    // Directional focus only considers widgets that have been built, so a
    // lazily built strip hands the remote back at the last realised card.
    // Twelve at 208 dp is twice the width of the panel.
    await mount(
      tester,
      movieWith([
        for (var i = 0; i < 12; i++)
          group('addon$i.example', [
            torrent(hash(i + 1), 'Release $i', '👤 5 💾 1 GB'),
          ]),
      ]),
    );
    expect(find.byType(TvSourceGroupCard), findsNWidgets(12));

    for (var i = 0; i < 20 && focusedLabel(tester) != 'addon11.example'; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focusedLabel(tester), 'addon11.example');
    // And it is on the panel, not off the end of the strip.
    final row = tester.getRect(find.byType(TvSourceRows));
    final card = tester.getRect(find.byType(TvSourceGroupCard).last);
    expect(card.left, greaterThanOrEqualTo(row.left));
    expect(card.right, lessThanOrEqualTo(row.right));
  });

  testWidgets('the D-pad reaches the last card of a row of sources far '
      'longer than fits', (tester) async {
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          for (var i = 0; i < 20; i++)
            torrent(hash(i + 1), 'Release $i', '👤 5 💾 1 GB'),
        ]),
      ]),
    );

    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(find.byType(TvSourceCard), findsNWidgets(20));
    for (var i = 0; i < 30 && focusedLabel(tester) != 'Release 19'; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focusedLabel(tester), 'Release 19');
  });

  testWidgets('off a television the sources are the vertical list they '
      'always were', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      harness(
        FakeCoreClient(
          state: {
            CoreField.metaDetails: movieWith([
              group('alpha.example', [
                torrent(hash(1), 'Alpha 1080p', '👤 20 💾 2 GB'),
              ]),
            ]),
          },
        ),
        device: DeviceProfile.fallback,
        prefs: await prefsFor(sectioned: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TvSourceRows), findsNothing);
    expect(find.byType(TvSourceGroupCard), findsNothing);
    expect(find.byKey(streamSectionKey(StreamResolution.fhd1080)), findsOne);
  });
}
