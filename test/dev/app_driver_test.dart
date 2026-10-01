import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/dev/driver/app_driver.dart';
import 'package:xtremio/core/media_ids.dart' show mediaIdUrl;

import '../support/player_harness.dart';

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
