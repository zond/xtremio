import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/dev/driver/app_driver.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';
import '../support/player_harness.dart';
import '../support/stream_groups.dart';
import '../../tool/drive.dart' as drive;

/// A screen with a header, a counter button and a switch: enough for
/// `screen` to group and `act` to change something it can read back.
class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _count = 0;
  bool _on = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      children: [
        Semantics(header: true, child: const Text('First section')),
        ElevatedButton(
          onPressed: () => setState(() => _count++),
          child: const Text('Press'),
        ),
        Text('Count $_count'),
        Semantics(header: true, child: const Text('Second section')),
        SwitchListTile(
          title: const Text('Lights'),
          value: _on,
          onChanged: (on) => setState(() => _on = on),
        ),
      ],
    ),
  );
}

/// A shell like the app's: a bottom bar whose destinations are found by
/// label, on a navigator reachable through the `MaterialApp`'s key.
class FakeRootShell extends StatefulWidget {
  const FakeRootShell({super.key});

  @override
  State<FakeRootShell> createState() => _FakeRootShellState();
}

class _FakeRootShellState extends State<FakeRootShell> {
  int _index = 0;
  static const _labels = ['Discover', 'Library', 'Settings'];

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(child: Text('${_labels[_index]} body')),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _index,
      onDestinationSelected: (i) => setState(() => _index = i),
      destinations: [
        for (final label in _labels)
          NavigationDestination(icon: const Icon(Icons.circle), label: label),
      ],
    ),
  );
}

class FakeDetailsScreen extends StatelessWidget {
  const FakeDetailsScreen(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Scaffold(appBar: AppBar(), body: Text(text));
}

List<Map<String, dynamic>> nodesOf(Map<String, Object?> screen) => [
  for (final s in screen['sections']! as List)
    for (final n in (s as Map)['nodes'] as List)
      (n as Map).cast<String, dynamic>(),
];

void main() {
  testWidgets('screen groups the nodes under their headers, and act taps one '
      'and answers the screen after', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _Counter()));
    final driver = AppDriver(settle: () => tester.pumpAndSettle());
    driver.ensureSemantics();
    await tester.pumpAndSettle();

    final screen = driver.screen();
    final sections = (screen['sections']! as List).cast<Map>();
    final headers = [for (final s in sections) s['header']];
    expect(headers, containsAllInOrder(['First section', 'Second section']));
    final first = sections.firstWhere((s) => s['header'] == 'First section');
    final press = (first['nodes'] as List).cast<Map>().firstWhere(
      (n) => n['label'] == 'Press',
    );
    expect(press['roles'], contains('button'));
    expect(press['actions'], contains('tap'));
    expect((press['rect'] as List).length, 4);
    final second = sections.firstWhere((s) => s['header'] == 'Second section');
    final lights = (second['nodes'] as List).cast<Map>().firstWhere(
      (n) => (n['label'] as String).contains('Lights'),
    );
    expect(lights['roles'], contains('toggled:off'));

    final after = await driver.act(press['id'] as int, 'tap', null);
    expect(find.text('Count 1'), findsOneWidget);
    expect(
      nodesOf(after).map((n) => n['label']),
      contains('Count 1'),
      reason: 'act answers the screen as it is after the tap',
    );

    final toggled = await driver.act(lights['id'] as int, 'tap', null);
    expect(
      nodesOf(
        toggled,
      ).firstWhere((n) => (n['label'] as String).contains('Lights'))['roles'],
      contains('toggled:on'),
    );

    driver.dispose();
  });

  testWidgets('act refuses an action the node does not take, through the '
      'handler as JSON', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _Counter()));
    final driver = AppDriver(settle: () => tester.pumpAndSettle());
    driver.ensureSemantics();
    await tester.pumpAndSettle();
    final count = driver.find(['Count 0'], const []).single;

    final answer = jsonDecode(
      await driver.handle(
        jsonEncode({'cmd': 'act', 'id': count['id'], 'action': 'longPress'}),
      ),
    ) as Map<String, dynamic>;

    expect(answer['error'], contains('does not support longPress'));
    driver.dispose();
  });

  testWidgets('find and tap match every term and none of the excluded', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final label in [
                'Show 720p | Torrentio RD',
                'Show 720p | Torrentio',
              ])
                TextButton(
                  onPressed: () => tappedLabels.add(label),
                  child: Text(label),
                ),
            ],
          ),
        ),
      ),
    );
    final driver = AppDriver(settle: () => tester.pumpAndSettle());
    driver.ensureSemantics();
    await tester.pumpAndSettle();

    expect(driver.find(['torrentio', '720p'], const []), hasLength(2));
    final tapped = await driver.tap(['Torrentio', '720p'], ['Torrentio RD']);

    expect(tapped['tapped'], 'Show 720p | Torrentio');
    expect(tappedLabels, ['Show 720p | Torrentio']);
    driver.dispose();
  });

  testWidgets('go selects a shell destination by label, pushes details and '
      'comes back down with the system back', (tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const FakeRootShell()),
    );
    final driver = AppDriver(
      settle: () => tester.pumpAndSettle(),
      details: (type, id, videoId) =>
          FakeDetailsScreen('details $type $id $videoId'),
    );
    driver.ensureSemantics();
    await tester.pumpAndSettle();

    var screen = await driver.go(['library']);
    expect(find.text('Library body'), findsOneWidget);
    expect(screen['tab'], 'Library');

    screen = await driver.go(['details', 'series', 'tt1', 'tt1:6:3']);
    expect(find.text('details series tt1 tt1:6:3'), findsOneWidget);
    final routes = (screen['routes']! as List).cast<Map>();
    expect(routes.map((r) => r['page']), [
      'FakeRootShell',
      'FakeDetailsScreen',
    ]);
    expect(routes.last['current'], isTrue);

    screen = await driver.go(['back']);
    expect(find.text('details series tt1 tt1:6:3'), findsNothing);
    expect((screen['routes']! as List), hasLength(1));

    // A tab from under a pushed page goes back to the shell first.
    await driver.go(['details', 'movie', 'tt2']);
    screen = await driver.go(['settings']);
    expect(find.text('Settings body'), findsOneWidget);
    expect((screen['routes']! as List), hasLength(1));

    final unknown = jsonDecode(
      await driver.handle(
        jsonEncode({
          'cmd': 'go',
          'args': ['nowhere'],
        }),
      ),
    ) as Map<String, dynamic>;
    expect(unknown['error'], contains('Discover, Library, Settings'));
    driver.dispose();
  });

  testWidgets('player answers what the engine was handed and how it plays', (
    tester,
  ) async {
    final driver = AppDriver(settle: () => tester.pumpAndSettle());
    expect(AppDriver.player()['players'], isEmpty);

    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine
      ..emitDuration(const Duration(minutes: 44))
      ..emitPlaying(true)
      ..emitPosition(const Duration(seconds: 12))
      ..emitBuffer(const Duration(seconds: 40));
    await tester.pump();

    final players = AppDriver.player()['players']! as List;
    final probe = (players.single as Map).cast<String, Object?>();
    expect(probe['engineUrl'], startsWith('${mediaIdUrl('m1')}'));
    expect(probe['mediaId'], 'm1');
    expect(probe['positionMs'], 12000);
    expect(probe['durationMs'], 44 * 60 * 1000);
    expect(probe['playing'], isTrue);
    expect(probe['bufferMs'], 40000);
    expect(probe['engineError'], isNull);
    driver.dispose();
  });

  testWidgets('seek moves the engine to a time or a share of the duration', (
    tester,
  ) async {
    final driver = AppDriver(settle: () => tester.pumpAndSettle());
    expect(() => driver.seek('1:00'), throwsStateError);

    final harness = PlayerHarness();
    await harness.pump(tester);
    harness.engine
      ..emitDuration(const Duration(minutes: 40))
      ..emitPlaying(true);
    await tester.pump();

    driver.seek('0:12:03');
    driver.seek('90');
    driver.seek('60%');
    await tester.pump();
    expect(harness.engine.seeks, [
      const Duration(minutes: 12, seconds: 3),
      const Duration(seconds: 90),
      const Duration(minutes: 24),
    ]);
    driver.dispose();
  });

  testWidgets('streams lists every source of the open title, built or not', (
    tester,
  ) async {
    await pumpDetails(tester, moreSourcesCore());
    final driver = AppDriver(settle: () => tester.pumpAndSettle());
    expect(
      find.textContaining('Night.of.the.Living.Dead.1968.1080p'),
      findsNothing,
      reason: 'every section is collapsed, so no row is built',
    );

    final answer = answerOf(
      await driver.handle(jsonEncode({'cmd': 'streams'})),
    );

    expect(answer['title'], 'Night of the Living Dead');
    expect(answer['layout'], 'sectioned');
    expect(answer['loading'], isFalse);
    final listed = streamsOf(answer);
    // Five watch services, the public-domain torrent and the four above.
    expect(answer['total'], 10);
    expect(listed, hasLength(10));
    expect([for (final s in listed) s['index']], List.generate(10, (i) => i));
    final link = listed.singleWhere((s) => s['kind'] == 'link');
    expect(link['addon'], 'debrid.example');
    expect(link['title'], contains('1080p.BluRay.x265.DDP5.1-GRP'));
    expect(link['resolution'], '1080p');
    expect(link['size'], '4.2 GB');
    expect(link['tags'], ['BluRay', 'HEVC']);
    expect(link['text'], hasLength(2), reason: 'the size line and the link');
    final sd = listed.singleWhere((s) => s['resolution'] == '720p');
    expect(sd['text'], [
      '👤 3 ⚙️ 1337x',
    ], reason: 'one line, whitespace collapsed');
    expect(
      link['filename'],
      'Night.of.the.Living.Dead.1968.1080p.BluRay.x265.DDP5.1-GRP.mkv',
    );
    final uhd = listed.singleWhere((s) => s['resolution'] == '2160p');
    expect(uhd['kind'], 'torrent');
    expect(uhd['seeders'], 12);
    expect(uhd['tags'], containsAll(['HDR', 'DV', 'HEVC', 'Atmos']));
    expect(listed.where((s) => s['kind'] == 'YouTube'), hasLength(1));
    expect(listed.where((s) => s['kind'] == 'external'), hasLength(5));
    expect(
      listed.where((s) => s['kind'] == 'external').map((s) => s['playable']),
      everyElement(isFalse),
    );
    driver.dispose();
  });

  testWidgets('streams filters like find: every word, none of the --not', (
    tester,
  ) async {
    await pumpDetails(tester, moreSourcesCore());
    final driver = AppDriver(settle: () => tester.pumpAndSettle());

    final all = streamsOf(driver.streams(const [], const []));
    final x265 = driver.streams(const ['X265', 'ddp'], const []);
    final notUhd = driver.streams(const ['x265'], const ['2160p']);

    expect(x265['total'], 10, reason: 'the total is the unfiltered count');
    final match = streamsOf(x265).single;
    expect(match['kind'], 'link');
    expect(
      match['index'],
      all.indexWhere((s) => s['kind'] == 'link'),
      reason: 'a filtered stream keeps the index play takes',
    );
    expect(streamsOf(notUhd).map((s) => s['index']), [match['index']]);
    expect(
      streamsOf(driver.streams(const ['true'], const [])),
      isEmpty,
      reason: 'the playable flag and the index are not text a row shows',
    );
    driver.dispose();
  });

  testWidgets('streams never answers a URL, a header or an info hash, as '
      'text or as JSON', (tester) async {
    await pumpDetails(tester, moreSourcesCore());
    final driver = AppDriver(settle: () => tester.pumpAndSettle());

    final json = await driver.handle(jsonEncode({'cmd': 'streams'}));
    final played = await driver.handle(
      jsonEncode({
        'cmd': 'play',
        'index': streamsOf(answerOf(json))
            .indexWhere((s) => s['kind'] == 'link'),
      }),
    );

    expect(answerOf(played)['error'], isNull);
    final text = drive.human('streams', answerOf(json));
    final playedText = drive.human('play', answerOf(played));
    expect(text, contains('1080p.BluRay.x265.DDP5.1-GRP'));
    expect(playedText, startsWith('played #'));
    for (final answer in [json, played, text, playedText]) {
      expect(answer, isNot(contains(debridKey)));
      expect(answer, isNot(contains('/resolve/film.mkv')));
      expect(answer, isNot(contains(proxySecret)));
      expect(answer, isNot(contains('bbbbbbbbbbbbbbbbbbbb')));
      expect(answer, isNot(contains('dQw4w9WgXcQ')));
      expect(answer, isNot(contains('primevideo')));
    }
    driver.dispose();
  });

  testWidgets('play opens a stream no row is built for, as a tap on its '
      'row does', (tester) async {
    final core = moreSourcesCore();
    final key = await pumpDetails(tester, core);
    final driver = AppDriver(settle: () => tester.pumpAndSettle());
    driver.ensureSemantics();
    final uhd = streamsOf(driver.streams(const ['2160p'], const [])).single;

    final answer = await driver.play(uhd['index'] as int);

    expect(find.byType(PlayerScreen), findsOneWidget);
    final load = core.dispatched.firstWhere((a) => a.field == CoreField.player);
    final args = loadArgs(load);
    expect(args['stream']['infoHash'], 'b' * 40);
    expect(
      args['streamRequest']['base'],
      'https://debrid.example/manifest.json',
    );
    expect((answer['played']! as Map)['index'], uhd['index']);
    final routes = (answer['routes']! as List).cast<Map>();
    expect(routes.last['name'], PlayerScreen.routeName);

    // Under the player the list still reads, and play says why it will not.
    await expectLater(
      driver.play(99),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('lists 10'),
        ),
      ),
    );
    expect(streamsOf(driver.streams(const [], const [])), hasLength(10));
    await expectLater(
      driver.play(uhd['index'] as int),
      throwsA(isA<StateError>()),
    );
    final external = streamsOf(driver.streams(const [], const []))
        .firstWhere((s) => s['kind'] == 'external');
    key.currentState!.pop();
    await tester.pumpAndSettle();
    await expectLater(
      driver.play(external['index'] as int),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('external'),
        ),
      ),
    );
    driver.dispose();
  });

  testWidgets('streams numbers the grouped layout in its own order', (
    tester,
  ) async {
    final prefs = AppPrefs.inMemory();
    unawaited(prefs.setStreamsSectioned(false));
    await pumpDetails(tester, moreSourcesCore(), prefs: prefs);
    final driver = AppDriver(settle: () => tester.pumpAndSettle());

    final answer = driver.streams(const [], const []);

    expect(answer['layout'], 'grouped');
    final listed = streamsOf(answer);
    expect(listed, hasLength(10));
    // The profile's order, WatchHub first; the sectioned list puts the
    // 2160p torrent first.
    expect(listed.first['addon'], 'WatchHub');
    expect(listed.last['kind'], 'YouTube');
    driver.dispose();
  });

  testWidgets('streams on a series says when no episode is picked and when '
      'a picked one has not answered yet', (tester) async {
    // A phone: only a narrow layout holds back the previous episode's
    // streams while the tapped one's are on their way.
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const seriesId = 'tt0903747';
    final core = FakeCoreClient(
      state: {CoreField.metaDetails: loadSeriesMetaDetailsFixture()},
    );
    await pumpDetails(tester, core, type: 'series', id: seriesId);
    final driver = AppDriver(settle: () => tester.pumpAndSettle());

    var answer = driver.streams(const [], const []);
    expect(answer['note'], 'no episode is picked yet');
    expect(answer['streams'], isEmpty);

    final episode = loadSeriesEpisodeMetaDetailsFixture();
    (episode['streams'] as List).add(
      readyGroup(
        'torrentio.example',
        [
          {
            'infoHash': 'a' * 40,
            'fileIdx': 3,
            'name': 'Torrentio\n1080p',
            'description': 'Breaking.Bad.S01E01.1080p.mkv\n👤 42 💾 1.51 GB',
          },
        ],
        type: 'series',
        id: '$seriesId:1:1',
      ),
    );
    core.setState(CoreField.metaDetails, episode);
    await tester.pumpAndSettle();
    answer = driver.streams(const [], const []);
    expect(answer['note'], isNull);
    expect(answer['videoId'], '$seriesId:1:1');
    expect(streamsOf(answer).map((s) => s['title']), [
      'Breaking.Bad.S01E01.1080p.mkv',
    ]);

    await tester.tap(find.text("Cat's in the Bag..."));
    await tester.pump();
    await tester.pump();
    answer = driver.streams(const [], const []);
    expect(answer['loading'], isTrue);
    expect(answer['note'], contains('have not come back yet'));
    expect(answer['videoId'], '$seriesId:1:2');
    expect(
      answer['streams'],
      isEmpty,
      reason: 'the pilot\'s streams are not the picked episode\'s',
    );
    driver.dispose();
  });

  testWidgets('streams with no details screen open says so', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _Counter()));
    final driver = AppDriver(settle: () => tester.pumpAndSettle());

    for (final cmd in [
      {'cmd': 'streams'},
      {'cmd': 'play', 'index': 0},
    ]) {
      expect(
        answerOf(await driver.handle(jsonEncode(cmd)))['error'],
        contains('no details screen is open'),
      );
    }
    driver.dispose();
  });

  testWidgets('streams says which addons are still answering', (tester) async {
    await pumpDetails(
      tester,
      moreSourcesCore(extra: [loadingGroup('slow.example')]),
      settle: false,
    );
    final driver = AppDriver(settle: () => tester.pumpAndSettle());

    final answer = driver.streams(const [], const []);

    expect(answer['loading'], isTrue);
    expect(answer['waitingFor'], ['slow.example']);
    expect(answer['total'], 10, reason: 'what has arrived is listed');
    driver.dispose();
  });

  testWidgets('streams on a title whose meta has not arrived says so', (
    tester,
  ) async {
    await pumpDetails(tester, FakeCoreClient(), settle: false);
    final driver = AppDriver(settle: () => tester.pumpAndSettle());

    final answer = driver.streams(const [], const []);

    expect(answer['loading'], isTrue);
    expect(answer['note'], 'the title has not loaded yet');
    expect(answer['streams'], isEmpty);
    driver.dispose();
  });

  test('tool/drive takes streams with or without words, and play an index', () {
    expect(drive.messageOf(['streams']), {
      'cmd': 'streams',
      'text': <String>[],
      'not': <String>[],
    });
    expect(drive.messageOf(['streams', 'x265', '--not', '2160p']), {
      'cmd': 'streams',
      'text': ['x265'],
      'not': ['2160p'],
    });
    expect(drive.messageOf(['play', '12']), {'cmd': 'play', 'index': 12});
    expect(() => drive.messageOf(['play']), throwsFormatException);
    expect(() => drive.messageOf(['find']), throwsFormatException);
  });

  test('log answers the last n lines, scrubbed of URLs', () {
    final driver = AppDriver(
      logLines: () => [
        'one',
        'two',
        'open https://addon.example/secretkey/stream/x.json',
      ],
    );

    final lines = driver.log(2)['lines']! as List;

    expect(lines, hasLength(2));
    expect(lines.first, 'two');
    expect(lines.last, isNot(contains('secretkey')));
  });
}

final tappedLabels = <String>[];

/// A debrid addon's link: the key is in the path, as real ones carry it.
const debridKey = 'SECRETKEY0123456789abcdef';
const debridUrl = 'https://debrid.example/$debridKey/resolve/film.mkv';
const proxySecret = 'PROXYSECRET42';

/// The public-domain movie fixture with one more addon answering four
/// streams: a debrid link with its key in the URL and a proxy header, two
/// torrents and a YouTube video.
FakeCoreClient moreSourcesCore({List<Map<String, dynamic>>? extra}) {
  final fixture = loadMetaDetailsFixture();
  (fixture['streams'] as List).add(
    readyGroup('debrid.example', [
      {
        'url': debridUrl,
        'name': 'Debrid\n1080p',
        'description':
            'Night.of.the.Living.Dead.1968.1080p.BluRay.x265.DDP5.1-GRP\n'
            '💾 4.2 GB\n'
            // Some addons write a link into the text; the row shows it, the
            // driver does not.
            'via $debridUrl',
        'behaviorHints': {
          'filename':
              'Night.of.the.Living.Dead.1968.1080p.BluRay.x265.DDP5.1-GRP.mkv',
          'proxyHeaders': {
            'request': {'Authorization': 'Bearer $proxySecret'},
          },
        },
      },
      {
        'infoHash': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'fileIdx': 1,
        'name': 'Debrid\n2160p',
        'description':
            'Night.of.the.Living.Dead.1968.2160p.UHD.HDR.DV.x265.Atmos\n'
            '👤 12 💾 30 GB',
      },
      {
        'infoHash': 'cccccccccccccccccccccccccccccccccccccccc',
        'fileIdx': 0,
        'name': 'Debrid\n720p',
        'description':
            'Night.of.the.Living.Dead.1968.720p.x264.DTS\n👤 3 \t  ⚙️ 1337x',
      },
      {'ytId': 'dQw4w9WgXcQ', 'name': 'Trailer'},
    ]),
  );
  if (extra != null) (fixture['streams'] as List).addAll(extra);
  return FakeCoreClient(
    state: {
      CoreField.metaDetails: fixture,
      CoreField.ctx: loadCtxLoggedOutFixture(),
      CoreField.player: loadPlayerFixture(),
    },
  );
}

/// The movie's details screen as the app pushes it, on the sources list's
/// default layout: sectioned by resolution with every section collapsed,
/// so no stream row is built at all.
///
/// A screen still loading draws a spinner that never settles, so
/// [settle] false pumps the frames that deliver the state and no more.
Future<GlobalKey<NavigatorState>> pumpDetails(
  WidgetTester tester,
  FakeCoreClient core, {
  bool settle = true,
  AppPrefs? prefs,
  String type = 'movie',
  String id = 'tt0063350',
}) async {
  final key = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    CoreScope(
      client: core,
      child: PrefsScope(
        prefs: prefs ?? AppPrefs.inMemory(),
        child: PlaybackScope(
          createEngine: FakePlaybackEngine.new,
          torrentStats: FakeTorrentStatsClient(),
          child: MaterialApp(
            navigatorKey: key,
            home: MetaDetailsScreen(type: type, id: id),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
  return key;
}

Map<String, dynamic> loadArgs(CoreAction action) =>
    (action.action['args'] as Map<String, dynamic>)['args']
        as Map<String, dynamic>;

Map<String, dynamic> answerOf(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

List<Map<String, dynamic>> streamsOf(Map<String, dynamic> answer) => [
  for (final s in answer['streams'] as List) (s as Map).cast<String, dynamic>(),
];
