import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_prefs_client.dart';

void main() {
  test('defaults to grouped streams until something is loaded', () async {
    final prefs = AppPrefs(client: FakePrefsClient());
    expect(prefs.streamsFlat, isFalse);
    await prefs.load();
    expect(prefs.streamsFlat, isFalse);
  });

  test('load reads a stored choice and notifies', () async {
    final prefs = AppPrefs(client: FakePrefsClient({'streamsFlat': true}));
    var notified = 0;
    prefs.addListener(() => notified++);

    await prefs.load();

    expect(prefs.streamsFlat, isTrue);
    expect(notified, 1);
  });

  test(
    'a change is written through and read back by a fresh AppPrefs',
    () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);

      await prefs.setStreamsFlat(true);
      expect(client.stored['streamsFlat'], isTrue);
      expect(client.writes, ['streamsFlat']);

      // A fresh app start over the same file.
      final restarted = AppPrefs(client: client);
      await restarted.load();
      expect(restarted.streamsFlat, isTrue);
    },
  );

  test('setting the value it already has writes nothing', () async {
    final client = FakePrefsClient();
    final prefs = AppPrefs(client: client);
    var notified = 0;
    prefs.addListener(() => notified++);

    await prefs.setStreamsFlat(false);

    expect(client.writes, isEmpty);
    expect(notified, 0);
  });

  test('a stored value of the wrong type is ignored', () async {
    final prefs = AppPrefs(client: FakePrefsClient({'streamsFlat': 'yes'}));
    await prefs.load();
    expect(prefs.streamsFlat, isFalse);
  });

  test('an unavailable file leaves the defaults and keeps the choice in '
      'memory', () async {
    final prefs = AppPrefs(client: FakePrefsClient.failing());

    await prefs.load();
    expect(prefs.streamsFlat, isFalse);

    // The write fails too; the value still holds for this run rather than
    // snapping back under the user's finger.
    await prefs.setStreamsFlat(true);
    expect(prefs.streamsFlat, isTrue);
  });

  test(
    'with no client at all nothing is persisted and nothing throws',
    () async {
      final prefs = AppPrefs.inMemory();
      await prefs.load();
      await prefs.setStreamsFlat(true);
      expect(prefs.streamsFlat, isTrue);
    },
  );

  testWidgets('PrefsScope hands the value down and rebuilds on a change', (
    tester,
  ) async {
    final prefs = AppPrefs(client: FakePrefsClient());
    addTearDown(prefs.dispose);
    final seen = <bool>[];

    await tester.pumpWidget(
      PrefsScope(
        prefs: prefs,
        child: Builder(
          builder: (context) {
            seen.add(PrefsScope.of(context).streamsFlat);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(seen, [false]);

    await prefs.setStreamsFlat(true);
    await tester.pump();
    expect(seen, [false, true]);
  });

  testWidgets('maybeOf is null with no scope above', (tester) async {
    AppPrefs? found = AppPrefs.inMemory();
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          found = PrefsScope.maybeOf(context);
          return const SizedBox.shrink();
        },
      ),
    );
    expect(found, isNull);
  });
}
