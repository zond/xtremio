import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addon_details_screen.dart';
import 'package:xtremio/features/addons/addons_screen.dart';
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

/// An addon that answered with an error the engine calls "nothing here".
Map<String, dynamic> emptyGroup(String host) => {
  ...group(host, const []),
  'content': {
    'type': 'Err',
    'content': {'type': 'EmptyContent'},
  },
};

/// An addon that could not answer at all.
Map<String, dynamic> failedGroup(String host) => {
  ...group(host, const []),
  'content': {
    'type': 'Err',
    'content': {
      'type': 'Env',
      'content': {'code': 1, 'message': 'Failed to fetch: 404 Not Found'},
    },
  },
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

/// The screen under the scopes it needs, as the app's only route -- or,
/// with [pushed], one press away from a route that stays behind it, which
/// is the only arrangement where leaving the screen is something a test
/// can see happen.
Widget harness(
  FakeCoreClient core, {
  DeviceProfile device = tv,
  required AppPrefs prefs,
  bool pushed = false,
}) => DeviceScope(
  profile: device,
  child: CoreScope(
    client: core,
    child: PrefsScope(
      prefs: prefs,
      child: PlaybackScope(
        createEngine: FakePlaybackEngine.new,
        torrentStats: FakeTorrentStatsClient(),
        child: MaterialApp(
          home: pushed
              ? Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const MetaDetailsScreen(
                            type: 'movie',
                            id: movieId,
                          ),
                        ),
                      ),
                      child: const Text('open the title'),
                    ),
                  ),
                )
              : const MetaDetailsScreen(type: 'movie', id: movieId),
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

Future<FakeCoreClient> mount(
  WidgetTester tester,
  Map<String, dynamic> fixture, {
  bool sectioned = false,
  DeviceProfile device = tv,
  Size size = tvSize,
  Map<CoreField, Map<String, dynamic>> also = const {},
  bool pushed = false,
  // A spinner never stops, so a screen with an addon still answering
  // cannot be settled; it is pumped a frame at a time instead.
  bool settle = true,
}) async {
  useScreen(tester, size);
  final core = FakeCoreClient(state: {CoreField.metaDetails: fixture, ...also});
  await tester.pumpWidget(
    harness(
      core,
      device: device,
      prefs: await prefsFor(sectioned: sectioned),
      pushed: pushed,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (pushed) {
    await tester.tap(find.text('open the title'));
    await tester.pumpAndSettle();
  }
  return core;
}

/// Whether a Back press would leave the screen rather than be taken by the
/// open row of sources.
///
/// The screen is the test app's only route, so a press that is *not* taken
/// leaves nothing behind to look at -- on a device it is the app exiting.
/// What the system Back asks is this `PopScope`, so this is the answer
/// itself rather than a stand-in for it.
bool backLeaves(WidgetTester tester) => tester
    .widgetList<PopScope<dynamic>>(find.byWidgetPredicate((w) => w is PopScope))
    .single
    .canPop;

/// The labels of the group row, left to right.
List<String> groupLabels(WidgetTester tester) => [
  for (final card in tester.widgetList<TvSourceGroupPill>(
    find.byType(TvSourceGroupPill),
  ))
    card.group.label,
];

/// The titles of the row of sources under it, left to right.
List<String> sourceTitles(WidgetTester tester) => [
  for (final card in tester.widgetList<TvSourceCard>(find.byType(TvSourceCard)))
    card.source.title,
];

/// The one line of facts the card titled [title] carries, in order.
List<String> factsOf(WidgetTester tester, String title) => tester
    .widgetList<TvSourceCard>(find.byType(TvSourceCard))
    .firstWhere((card) => card.source.title == title)
    .source
    .facts;

/// Walks down the ladder to the header of the rung called [label] and
/// presses select on it, which opens that rung and shuts whichever was
/// open.
Future<void> openRung(
  WidgetTester tester,
  String label, {
  int limit = 8,
}) async {
  for (var i = 0; i < limit && focusedLabel(tester) != label; i++) {
    await press(tester, LogicalKeyboardKey.arrowDown);
  }
  expect(focusedLabel(tester), label, reason: 'the walk reached $label');
  await press(tester, LogicalKeyboardKey.select);
}

/// What the strip under the row of sources is saying, top line first: the
/// release in full, and -- when there is one -- the line of everything the
/// card had to drop.
List<String> stripLines(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(
      of: find.byType(TvSourceDetailStrip),
      matching: find.byType(Text),
    ),
  ))
    text.data!,
];

/// Everything drawn inside the card titled [title].
Finder inSource(String title, Finder matching) => find.descendant(
  of: find.byWidgetPredicate(
    (w) => w is TvSourceCard && w.source.title == title,
  ),
  matching: matching,
);

/// A stream the player cannot open, the way WatchHub answers: a card the
/// remote steps over rather than one it can be left on.
Map<String, dynamic> externalStream(String name) => {
  'externalUrl': 'https://example.com/$name',
  'name': name,
  'description': 'Subscription',
};

/// A release with everything a card had to drop on it: the source, the
/// codec, the dynamic range and the audio, and two addons offering the
/// very same file.
const sharedRelease = 'Alpha.2001.1080p.WEB-DL.x265.HDR.Atmos-GRP';
Map<String, dynamic> sharedByTwoAddons() => movieWith([
  group('alpha.example', [
    torrent(hash(1), 'Alpha\n1080p', '$sharedRelease\n👤 42 💾 1.5 GB'),
  ]),
  group('beta.example', [
    torrent(hash(1), 'Beta\n1080p', '$sharedRelease\n👤 42 💾 1.5 GB'),
  ]),
]);

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

    // The rung the remote starts on has its row out: both addons' 1080p
    // releases, in the order the chips choose (peers per megabyte: beta's
    // ninety peers over the same two gigabytes), and nothing of 720p's.
    expect(sourceTitles(tester), ['Beta 1080p', 'Alpha 1080p']);

    // And the next rung along lists its own, and only its own.
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(sourceTitles(tester), ['Alpha 720p']);
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
    // A pill says how many are behind it, and nothing else: it is a word
    // wide, and the swarm is on every card of the row it opens.
    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is TvSourceGroupPill && w.group.label == 'alpha.example',
        ),
        matching: find.text('· 2'),
      ),
      findsOneWidget,
    );

    await press(tester, LogicalKeyboardKey.select);
    expect(sourceTitles(tester), ['Alpha 1080p', 'Alpha 720p']);
  });

  testWidgets('a source card leads with the release and says the rest on '
      'one line', (tester) async {
    // Written the way Torrentio writes them: the name is the addon and
    // the quality, and the release is the first line of the description.
    // The card that led with the name read "Torrentio" four times over.
    const release = 'Alpha.2001.1080p.BluRay.x264-CiNEFiLE';
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha\n1080p', '$release\n👤 42 💾 1.5 GB'),
        ]),
        group('beta.example', [
          torrent(hash(1), 'Beta\n1080p', '$release\n👤 42 💾 1.5 GB'),
        ]),
      ]),
      sectioned: true,
    );

    // One release is one card, whichever addon it came from -- and the
    // release is the headline, with somewhere to break it at every dot.
    expect(sourceTitles(tester), [release]);
    expect(inSource(release, find.text(breakableRelease(release))), findsOne);
    // The pill above says the resolution, so the card says the two facts
    // it cannot, and the addon that answered -- with a +1 for the other
    // one that offered the very same source.
    expect(factsOf(tester, release), [
      '42 seeders',
      '1.5 GB',
      'alpha.example +1',
    ]);
    expect(
      inSource(release, find.text('42 seeders · 1.5 GB · alpha.example +1')),
      findsOne,
    );
  });

  testWidgets('says everything the card had to drop, and nothing it '
      'already says', (tester) async {
    await mount(tester, sharedByTwoAddons(), sectioned: true);

    // The card leads with the release and truncates it at two lines;
    // the strip carries it in full and on one, and under it the tags
    // that went when the card was cut to 260x96 -- with the `+1` on the
    // card's own line spelled out into which addon it was.
    expect(stripLines(tester), [
      sharedRelease,
      'Torrent · WEB-DL · HDR · HEVC · Atmos · also from beta.example',
    ]);
    expect(
      tester.getRect(find.byType(TvSourceDetailStrip)).height,
      TvSourceRows.detailHeight,
    );
    // And none of what the card is already saying: the swarm, the size
    // and the addon that answered are on it, an arm's length above.
    expect(factsOf(tester, sharedRelease), [
      '42 seeders',
      '1.5 GB',
      'alpha.example +1',
    ]);
  });

  testWidgets('is right on the first frame, with nothing pressed', (
    tester,
  ) async {
    // The trap: a strip driven only by cards reporting focus is blank
    // here. The remote starts on the group pill above the row, so no
    // card holds focus at all -- and the tile that autofocuses is
    // deliberately silent about it either way. A film nobody has played
    // opens exactly like this, so blank would be the common case.
    await mount(tester, sharedByTwoAddons(), sectioned: true);

    expect(focusIn<TvSourceCard>(), isFalse, reason: 'still on the pill');
    expect(focusIn<TvSourceGroupPill>(), isTrue);
    expect(
      stripLines(tester).first,
      sourceTitles(tester).first,
      reason: 'the card the row would hand the remote back',
    );
  });

  testWidgets('follows the remote along the row', (tester) async {
    // The grouped layout, where a pill is an addon: it ranks inside one
    // addon's own answer and reads nothing out of the streams, so the
    // tags the strip carries are read here and nowhere else.
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p', '👤 90 💾 2 GB'),
          torrent(hash(2), 'Beta 1080p WEB-DL x265', '👤 20 💾 2 GB'),
        ]),
      ]),
    );

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'Alpha 1080p');
    expect(stripLines(tester), ['Alpha 1080p', 'Torrent']);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Beta 1080p WEB-DL x265');
    expect(stripLines(tester), [
      'Beta 1080p WEB-DL x265',
      'Torrent · WEB-DL · HEVC',
    ]);
  });

  testWidgets('a source with nothing more to say still draws its release '
      'rather than an empty box', (tester) async {
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p', '👤 20 💾 2 GB'),
        ]),
      ]),
      sectioned: true,
    );

    // No tags, no other addon, and the addon sent no filename: what is
    // left is the release and what kind of source it is, which the card
    // says with an icon and nothing else. Not a placeholder for what is
    // not known, and not a box of the same height with nothing in it.
    expect(stripLines(tester), ['Alpha 1080p', 'Torrent']);
    expect(
      tester.getRect(find.byType(TvSourceDetailStrip)).height,
      TvSourceRows.detailHeight,
    );
  });

  testWidgets('a row the remote cannot enter still says what its first '
      'card is', (tester) async {
    // WatchHub answers with `externalUrl`s: not one card in the row is a
    // focus stop, so there is no card the remote is on and none it will
    // be handed. The strip is about the only card it could mean, and it
    // has nothing to say under the name -- which is a line left out, not
    // a line of placeholders for what is not known.
    await mount(tester, loadMetaDetailsFixture());

    expect(groupLabels(tester).first, 'watchhub.strem.io');
    expect(stripLines(tester), [sourceTitles(tester).first]);
    // And the box is the full reserved height with one line in it, the
    // same as the two-line one above: what the strip says changes as the
    // remote walks, and nothing about the panel does.
    expect(
      tester.getRect(find.byType(TvSourceDetailStrip)).height,
      TvSourceRows.detailHeight,
    );
  });

  testWidgets('a group whose sources have not arrived has nothing to '
      'describe, and draws no strip', (tester) async {
    // A pill is out for an addon that is still answering, and landing on
    // it opens a row with no cards in it. The strip is nothing but what
    // it says about a card, so there is none -- rather than a box asking
    // an empty list for its first entry.
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p', '\u{1f464} 20 \u{1f4be} 2 GB'),
        ]),
        {...group('slow.example', const []), 'content': null},
      ]),
      settle: false,
    );
    expect(groupLabels(tester), ['alpha.example', 'slow.example']);
    expect(find.byType(TvSourceDetailStrip), findsOneWidget);

    // Raw presses: a rung with an addon still out spins, and settling
    // never comes back.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(focusedLabel(tester), 'slow.example');
    expect(find.byType(TvSourceCard), findsNothing);
    expect(find.byType(TvSourceDetailStrip), findsNothing);
  });

  testWidgets('down from a source card lands on the next rung, never on '
      'the strip', (tester) async {
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p', '👤 20 💾 2 GB'),
        ]),
        emptyGroup('quiet.example'),
      ]),
      sectioned: true,
      also: {CoreField.ctx: loadCtxLoggedOutFixture()},
    );

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'Alpha 1080p');

    await press(tester, LogicalKeyboardKey.arrowDown);

    expect(focusedLabel(tester), kSourceAccountingLabel);
    expect(
      focusIn<TvSourceDetailStrip>(),
      isFalse,
      reason: 'a readout is not somewhere the D-pad can be left standing',
    );
  });

  testWidgets('another group is another set of cards, and the strip is '
      'about the one that row will hand back', (tester) async {
    // The card the remote was on is an index into the row it was in, and
    // the row a sideways press puts out is a different list -- with a
    // card no press can reach at the head of it. Carried across, that
    // index is a readout about a card the viewer is not about to land on:
    // a value read once and trusted after the thing it was read from has
    // been replaced.
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          // Nothing says how many peers any of these have, so the order
          // is the one they arrive in and the external stays at the head
          // of its own rung.
          torrent(hash(1), 'Alpha 2160p a', '💾 2 GB'),
          torrent(hash(2), 'Alpha 2160p b', '💾 2 GB'),
          externalStream('Rent 1080p'),
          torrent(hash(3), 'Alpha 1080p a', '💾 2 GB'),
          torrent(hash(4), 'Alpha 1080p b', '💾 1 GB'),
        ]),
      ]),
      sectioned: true,
    );
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Alpha 2160p b', reason: 'the second card');

    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowRight);

    expect(sourceTitles(tester), [
      'Rent 1080p',
      'Alpha 1080p a',
      'Alpha 1080p b',
    ]);
    expect(stripLines(tester).first, 'Alpha 1080p b');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(
      focusedLabel(tester),
      'Alpha 1080p b',
      reason: 'which is where down went',
    );
  });

  testWidgets('a rung opened again describes the card it will hand back, '
      'not the first one', (tester) async {
    // Closing the rung takes the row -- and everything this widget was
    // keeping about it -- off the screen, but not the ladder's own note of
    // where the remote was in that row. Two answers to "which card is this
    // row on" disagree the moment one of them is wrong, and what the
    // viewer sees then is a readout for a card they are not about to
    // reach.
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p a', '👤 90 💾 2 GB'),
          torrent(hash(2), 'Alpha 1080p b', '👤 20 💾 2 GB'),
        ]),
        emptyGroup('quiet.example'),
      ]),
      sectioned: true,
      also: {CoreField.ctx: loadCtxLoggedOutFixture()},
    );
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Alpha 1080p b');

    // Away into the rung below, which shuts this one, and back.
    await openRung(tester, kSourceAccountingLabel);
    expect(find.byType(TvSourceDetailStrip), findsNothing);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.select);

    expect(stripLines(tester).first, 'Alpha 1080p b');
    // The walk back down to the row it is describing: the header, the two
    // rungs of the heading's own controls, and the pills.
    for (var i = 0; i < 6 && !focusIn<TvSourceCard>(); i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(
      focusedLabel(tester),
      'Alpha 1080p b',
      reason: 'which is where down went',
    );
  });

  testWidgets('walking up to the pills and back leaves the panel where it '
      'was', (tester) async {
    // The reason it is not opened and closed with focus: a strip that
    // came and went as the remote entered and left the row would reflow
    // the panel on every step of that walk, with the row below jumping
    // and the scroll that keeps a focused card visible fighting it.
    await mount(tester, sharedByTwoAddons(), sectioned: true);

    // Measured against the rows themselves rather than the panel, so
    // that the scroll a focused card asks for is not read as a reflow.
    ({Size rows, Size strip, double gap}) layout() {
      final rows = tester.getRect(find.byType(TvSourceRows));
      final strip = tester.getRect(find.byType(TvSourceDetailStrip));
      return (rows: rows.size, strip: strip.size, gap: strip.top - rows.top);
    }

    final onThePills = layout();
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<TvSourceCard>(), isTrue);
    expect(layout(), onThePills, reason: 'down onto a card');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<TvSourceGroupPill>(), isTrue);
    expect(layout(), onThePills, reason: 'and back up to the pill');
  });

  testWidgets('is not drawn when the sources rung is shut', (tester) async {
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

    // The title has been played, so the rung that is open is the
    // last-used source -- one card, on a row of its own, with nothing
    // under it to strip.
    expect(find.text(kContinueWithLastSource), findsOneWidget);
    expect(find.byType(TvSourceGroupPill), findsNothing);
    expect(find.byType(TvSourceDetailStrip), findsNothing);
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
    // And the card says why, at the head of its line of facts.
    expect(factsOf(tester, 'Amazon Prime Video').first, 'External');
  });

  testWidgets('a title that has been played opens on the last-used source, '
      'with the remote already on it', (tester) async {
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
    // Its rung is above the sources, and the sources are shut: one rung
    // is open at a time, and this is the one the title is for.
    expect(
      tester.getTopLeft(find.text(kContinueWatchingLabel)).dy,
      lessThan(tester.getTopLeft(find.text(kSourcesLabel)).dy),
    );
    expect(find.byType(TvSourceGroupPill), findsNothing);
    // It says which release it is -- on the card, and on the shut rung's
    // own line, which is all a viewer needs to tell it from picking
    // another.
    expect(
      inSource(kContinueWithLastSource, find.text('Alpha 1080p')),
      findsOneWidget,
    );
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(PlayerScreen), findsOneWidget);
  });

  testWidgets('the last-used card arriving after the streams takes the '
      'remote, which has not been moved', (tester) async {
    // Opening a title from a continue-watching card: the addons answer
    // with streams before the engine has said which source the title was
    // last played from, so the card the screen wants the remote on is
    // built after the row that stands in for it. Nobody has touched the
    // D-pad, so the start of the screen is still the screen's to choose.
    List<Map<String, dynamic>> streams() => [
      group('alpha.example', [
        torrent(hash(1), 'Alpha 1080p', '\u{1f464} 20 \u{1f4be} 2 GB'),
      ]),
    ];
    final core = await mount(tester, movieWith(streams()));
    expect(focusedLabel(tester), 'alpha.example');

    core.setState(CoreField.metaDetails, withLastUsed(movieWith(streams())));
    await tester.pumpAndSettle();

    expect(focusedLabel(tester), kContinueWithLastSource);
  });

  testWidgets('the last-used card appearing leaves the remote on the card '
      'it was on', (tester) async {
    // The engine writes the last-used source down while the player is up,
    // so the first time a title is played the screen comes back to a
    // sliver list one longer than it left -- and the card the viewer was
    // on has to still be the card the D-pad answers, or coming out of the
    // player moves the remote for no reason the viewer can see.
    List<Map<String, dynamic>> streams() => [
      group('alpha.example', [
        torrent(hash(1), 'Alpha 1080p', '\u{1f464} 20 \u{1f4be} 2 GB'),
        torrent(hash(2), 'Alpha 720p', '\u{1f464} 30 \u{1f4be} 900 MB'),
      ]),
    ];
    final core = await mount(tester, movieWith(streams()));
    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Alpha 720p');

    core.setState(CoreField.metaDetails, withLastUsed(movieWith(streams())));
    await tester.pumpAndSettle();

    // The rung it arrives on is drawn and shut: the viewer is standing in
    // another one, and opening this would take the card they are on off
    // the screen.
    expect(find.text(kContinueWatchingLabel), findsOneWidget);
    expect(focusedLabel(tester), 'Alpha 720p');
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
    expect(find.byType(TvSourceGroupPill), findsNWidgets(12));

    for (var i = 0; i < 20 && focusedLabel(tester) != 'addon11.example'; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focusedLabel(tester), 'addon11.example');
    // And it is on the panel, not off the end of the strip.
    final row = tester.getRect(find.byType(TvSourceRows));
    final card = tester.getRect(find.byType(TvSourceGroupPill).last);
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

  testWidgets('a sideways press at the end of a row stays in the row', (
    tester,
  ) async {
    // Directional focus takes the nearest node in the direction pressed,
    // and the nearest thing to the right of the last card is not in the
    // row at all -- it was the layout toggle in the header, three rows
    // up, reached by a press that reads as "next card".
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p a', '\u{1f464} 5 \u{1f4be} 1 GB'),
          torrent(hash(2), 'Alpha 1080p b', '\u{1f464} 5 \u{1f4be} 1 GB'),
          torrent(hash(3), 'Alpha 720p', '\u{1f464} 5 \u{1f4be} 1 GB'),
        ]),
      ]),
      sectioned: true,
    );

    // The group row: left at the first rung and right past the last.
    expect(focusedLabel(tester), '1080p');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedLabel(tester), '1080p');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), '720p');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), '720p');
    expect(focusIn<TvSourceGroupPill>(), isTrue);

    // And the row of sources it opens, which is the one with cards wide
    // enough to run off the panel.
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedLabel(tester), 'Alpha 1080p a');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedLabel(tester), 'Alpha 1080p a');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Alpha 1080p b');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), 'Alpha 1080p b');
    expect(focusIn<TvSourceCard>(), isTrue);

    // Up and down still leave: only the two keys that run along the row
    // are taken.
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<TvSourceGroupPill>(), isTrue);
  });

  testWidgets('a rung the streams stop offering stops taking the Back '
      'press with it', (tester) async {
    // The row is drawn for a group that is *there*, so a label naming one
    // that has gone is nothing open -- and Back has to agree, or the press
    // that should have left the screen is swallowed by a row nobody can
    // see. Streams are re-fetched, dead addons come back, and picking an
    // episode from the row above replaces the lot.
    final core = await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p', '\u{1f464} 20 \u{1f4be} 2 GB'),
          torrent(hash(2), 'Alpha 720p', '\u{1f464} 30 \u{1f4be} 900 MB'),
        ]),
      ]),
      sectioned: true,
    );
    // Open on arrival: the remote lands on the group and its row is out,
    // with no select -- which would carry the remote down into the row.
    expect(sourceTitles(tester), ['Alpha 1080p']);
    expect(backLeaves(tester), isFalse, reason: 'a row is open');

    core.setState(
      CoreField.metaDetails,
      movieWith([
        group('alpha.example', [
          torrent(hash(2), 'Alpha 720p', '\u{1f464} 30 \u{1f4be} 900 MB'),
        ]),
      ]),
    );
    await tester.pumpAndSettle();

    expect(groupLabels(tester), ['720p']);
    expect(sourceTitles(tester), isEmpty, reason: 'the row went with 1080p');
    expect(backLeaves(tester), isTrue);
  });

  testWidgets('the addons that failed and the ones that had nothing are '
      'the card at the end of the row', (tester) async {
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p', '👤 20 💾 2 GB'),
        ]),
        emptyGroup('quiet.example'),
        failedGroup('mirror.example'),
      ]),
      also: {CoreField.ctx: loadCtxLoggedOutFixture()},
    );

    // A rung of its own below the sources, counting both without being
    // opened at all: what the addons did is not a group of sources, and
    // its one line is exactly what a rung header has room for and a 36 dp
    // pill has not.
    expect(groupLabels(tester), ['alpha.example']);
    expect(find.text(kSourceAccountingLabel), findsOneWidget);
    expect(
      find.text('1 addons did not answer · 1 addon had nothing for this title'),
      findsOneWidget,
    );

    await openRung(tester, kSourceAccountingLabel);
    expect(sourceTitles(tester), ['mirror.example', 'quiet.example']);
    expect(
      inSource('mirror.example', find.text('Failed to fetch: 404 Not Found')),
      findsOneWidget,
    );
    expect(
      inSource('quiet.example', find.text(kAddonHadNothing)),
      findsOneWidget,
    );

    // Select on the dead one opens its details, whose manifest fetch is
    // the reachability test.
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedLabel(tester), 'mirror.example');
    // Not `press`: the screen it pushes fetches the manifest and spins
    // while it waits, so nothing ever settles.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AddonDetailsScreen), findsOneWidget);
  });

  testWidgets('every addon that had nothing is named on a card the remote '
      'can reach', (tester) async {
    // A phone unfolds the summary into a name per line. Joined into one
    // card's second line here, the fourth name is already ellipsized and
    // there is no press that shows the rest -- and with nothing in the
    // row taking focus, the row cannot even be scrolled to it.
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p', '\u{1f464} 20 \u{1f4be} 2 GB'),
        ]),
        for (final host in ['one', 'two', 'three', 'four', 'five'])
          emptyGroup('$host.example'),
      ]),
      also: {CoreField.ctx: loadCtxLoggedOutFixture()},
    );

    expect(
      find.text('5 addons had nothing for this title'),
      findsOneWidget,
      reason: 'the shut rung still counts them',
    );
    await openRung(tester, kSourceAccountingLabel);
    expect(sourceTitles(tester), [
      'one.example',
      'two.example',
      'three.example',
      'four.example',
      'five.example',
    ]);

    // And the remote walks to the last of them, which is off the panel:
    // five cards 300 wide is more than a 720p television is.
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 8 && focusedLabel(tester) != 'five.example'; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focusedLabel(tester), 'five.example');
    // The accounting is a rung of its own, so what has to hold the last
    // card is its one row rather than the two the sources are.
    final row = tester.getRect(find.byType(TvSourceRow));
    final card = tester.getRect(find.byType(TvSourceCard).last);
    expect(card.left, greaterThanOrEqualTo(row.left));
    expect(card.right, lessThanOrEqualTo(row.right));
  });

  testWidgets('nobody having anything at all names the rung, and the screen '
      'opens on it', (tester) async {
    await mount(
      tester,
      movieWith([emptyGroup('quiet.example'), emptyGroup('silent.example')]),
    );

    // There is no sources rung to open -- nothing answered with one -- so
    // this is the rung the screen is for, and the remote is on the one
    // thing there is to press rather than nowhere at all.
    expect(groupLabels(tester), isEmpty);
    expect(find.text('No streams for this title'), findsOneWidget);
    expect(find.text('2 addons had nothing for this title'), findsOneWidget);
    expect(sourceTitles(tester).first, 'Add an addon');
    expect(focusedLabel(tester), 'Add an addon');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AddonsScreen), findsOneWidget);
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
    expect(find.byType(TvSourceGroupPill), findsNothing);
    expect(find.byKey(streamSectionKey(StreamResolution.fhd1080)), findsOne);
  });

  testWidgets('the back arrow leaves the screen with a row open', (
    tester,
  ) async {
    // The arrow is an explicit way out rather than a Back press: a
    // `Navigator.maybePop` here is answered by the rung the open row
    // holds, so the press a viewer aimed at the way out would put the row
    // away and leave them on the screen. The key keeps its ladder --
    // `backLeaves` below is that ladder, still holding the press -- and
    // the two differ on purpose.
    await mount(
      tester,
      movieWith([
        group('alpha.example', [
          torrent(hash(1), 'Alpha 1080p', '\u{1f464} 20 \u{1f4be} 2 GB'),
          torrent(hash(2), 'Alpha 720p', '\u{1f464} 30 \u{1f4be} 900 MB'),
        ]),
      ]),
      sectioned: true,
      pushed: true,
    );
    await press(tester, LogicalKeyboardKey.select);
    expect(sourceTitles(tester), ['Alpha 1080p']);
    expect(backLeaves(tester), isFalse, reason: 'a row is open');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(MetaDetailsScreen), findsNothing);
  });
}
