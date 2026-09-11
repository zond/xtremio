import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/diagnostics/server_storage_screen.dart';

import '../support/fake_server_cache.dart';

void main() {
  group('the report the server writes', () {
    test('a key this build has no meaning for adds no line to it', () {
      // The report is JSON from the embedded server, and this model is the
      // parser for it. `downloadsVolume` is what a *previous* build's
      // report carried, from when a kept download had a volume of its own
      // to be on: there is one root now, one volume under it, and a build
      // that went back to reading a second one would put a line in every
      // copied diagnostics report about a directory nothing writes to.
      final report = ServerStorage.fromJson({
        'cacheDir': '/data/cache/server',
        'cacheUsedBytes': 17000000000,
        'cacheLimitBytes': 10737418240,
        'cacheVolume': {
          'path': '/data/cache/server',
          'freeBytes': 402653184,
          'totalBytes': 57000000000,
        },
        'downloadsVolume': {
          'path': '/storage/emulated/0/Android/data/com.zond.xtremio/files',
          'freeBytes': 12000000000,
          'totalBytes': 128000000000,
        },
        'somethingALaterBuildAdds': {'bytes': 1},
      });

      expect(report.reportLines, [
        'cache: 17.0 GB of 10.7 GB limit · /data/cache/server',
        'disk: 403 MB free of 57.0 GB',
      ]);
    });
  });

  testWidgets('says what the cache costs and that it is over its limit', (
    tester,
  ) async {
    final client = FakeServerCache(usage: overLimitEvictable);
    await tester.pumpWidget(
      MaterialApp(home: ServerStorageScreen(client: client)),
    );
    await tester.pumpAndSettle();

    expect(find.text('17.0 GB of 10.0 GB limit'), findsOneWidget);
    expect(
      find.textContaining('Over its limit'),
      findsOneWidget,
      reason: 'a cache the server cannot bring under is the thing to notice',
    );
    expect(client.cleans, 0, reason: 'nothing was asked of the server yet');
  });

  testWidgets('says what is kept the way the server keeps it', (tester) async {
    // There is no scheduled sweep any more, and what a clean never takes
    // is a kept download and the title played last -- kept with the player
    // closed, which is exactly when a clean that frees nothing needs
    // explaining. "A live stream" sent the viewer looking for one.
    final client = FakeServerCache(
      usage: overLimitNothingEvictable,
      cleanResult: const EvictionReport(
        total: 12000000000,
        protected: 12000000000,
        protectedFiles: 3,
        freed: 0,
        deleted: 0,
        limit: 10000000000,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: ServerStorageScreen(client: client)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('hourly'), findsNothing);
    expect(find.textContaining('live stream'), findsNothing);
    expect(find.textContaining('the title played last'), findsOneWidget);
    expect(find.textContaining('the title you played last'), findsOneWidget);

    await tester.tap(find.text('Clean cache now'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('a download you kept or the title you played last'),
      findsOneWidget,
    );
  });

  testWidgets('cleaning runs immediately and reports what it freed', (
    tester,
  ) async {
    final client = FakeServerCache(
      usage: overLimitEvictable,
      cleanResult: const EvictionReport(
        total: 10000000000,
        protected: 0,
        protectedFiles: 0,
        freed: 7000000000,
        deleted: 4,
        limit: 10000000000,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: ServerStorageScreen(client: client)),
    );
    await tester.pumpAndSettle();

    // No confirmation to get past: cleaning no longer stops playback.
    await tester.tap(find.text('Clean cache now'));
    await tester.pumpAndSettle();

    expect(client.cleans, 1);
    expect(find.textContaining('Freed 7.0 GB from 4 files'), findsOneWidget);
    // And the numbers are read again afterwards.
    expect(client.reads, 2);
  });

  testWidgets('a clean that leaves the cache over its limit explains what is '
      'protected rather than saying it failed', (tester) async {
    final client = FakeServerCache(
      usage: overLimitNothingEvictable,
      cleanResult: const EvictionReport(
        total: 12000000000,
        protected: 12000000000,
        protectedFiles: 3,
        freed: 0,
        deleted: 0,
        limit: 10000000000,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: ServerStorageScreen(client: client)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clean cache now'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not clean'), findsNothing);
    expect(
      find.textContaining('Nothing more can be freed right now'),
      findsOneWidget,
    );
    expect(find.textContaining('holding 12.0 GB'), findsOneWidget);
  });

  testWidgets('a server that is not running says so and cleans nothing', (
    tester,
  ) async {
    final client = FakeServerCache(usageError: StateError('not running'));
    await tester.pumpWidget(
      MaterialApp(home: ServerStorageScreen(client: client)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage unavailable'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(client.cleans, 0);
  });

  testWidgets('a clean call that fails degrades to a message, not a crash', (
    tester,
  ) async {
    final client = FakeServerCache(
      usage: overLimitEvictable,
      cleanError: StateError('not running'),
    );
    await tester.pumpWidget(
      MaterialApp(home: ServerStorageScreen(client: client)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clean cache now'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Could not clean'), findsOneWidget);
    expect(client.cleans, 1);
  });

  testWidgets('a clean on a volume with no room to give still says what is '
      'holding it', (tester) async {
    // A cap of exactly 0 is what the server reports for a device whose
    // occupancy plus free space is under its 512 MiB floor: the tightest
    // cap there is, on the device most in need of an answer. Read as the
    // old "0 means no limit" sentinel it came out as "Nothing needed
    // cleaning." on a machine that was completely full.
    final client = FakeServerCache(
      usage: overLimitNothingEvictable,
      cleanResult: const EvictionReport(
        total: 12000000000,
        protected: 12000000000,
        protectedFiles: 3,
        freed: 0,
        deleted: 0,
        limit: 0,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: ServerStorageScreen(client: client)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clean cache now'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing needed cleaning'), findsNothing);
    expect(
      find.textContaining('Nothing more can be freed right now'),
      findsOneWidget,
    );
  });

  testWidgets('a clean with nothing capping the cache did need nothing', (
    tester,
  ) async {
    // The other side of the same field: null is the absence of a cap --
    // no `cacheSize` and a volume that would not answer -- and there is
    // then nothing for the cache to be over.
    final client = FakeServerCache(
      usage: overLimitEvictable,
      cleanResult: const EvictionReport(
        total: 12000000000,
        protected: 0,
        protectedFiles: 0,
        freed: 0,
        deleted: 0,
        limit: null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: ServerStorageScreen(client: client)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clean cache now'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing needed cleaning'), findsOneWidget);
  });

  group('where torrent data lives', () {
    testWidgets('names the one root and the room on its volume', (
      tester,
    ) async {
      final client = FakeServerCache(usage: overLimitEvictable);
      await tester.pumpWidget(
        MaterialApp(
          home: ServerStorageScreen(
            client: client,
            roots: () async => const [],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(ServerStorageScreen.rootTitle), findsOneWidget);
      expect(find.text('/data/cache/server'), findsWidgets);
      expect(find.text('403 MB free of 57.0 GB'), findsOneWidget);
    });

    testWidgets('a typed folder is written to cacheRoot, and only takes '
        'effect at the next start', (tester) async {
      final client = FakeServerCache(usage: overLimitEvictable);
      await tester.pumpWidget(
        MaterialApp(
          home: ServerStorageScreen(
            client: client,
            roots: () async => const [],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '/media/torrents');
      await tester.tap(find.text('Use this folder'));
      await tester.pumpAndSettle();

      expect(client.patches, [
        {'cacheRoot': '/media/torrents'},
      ], reason: 'one settings key, like every other');
      expect(
        find.text(ServerStorageScreen.movedMessage('/media/torrents')),
        findsOneWidget,
        reason: 'the running torrent session cannot be moved onto it',
      );
      expect(find.text('/media/torrents'), findsWidgets);
    });

    testWidgets('a volume the platform offers is picked rather than typed', (
      tester,
    ) async {
      final client = FakeServerCache(usage: overLimitEvictable);
      await tester.pumpWidget(
        MaterialApp(
          home: ServerStorageScreen(
            client: client,
            roots: () async => const ['/data/cache/server', '/storage/ABCD/x'],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('/storage/ABCD/x'));
      await tester.pumpAndSettle();

      expect(client.patches, [
        {'cacheRoot': '/storage/ABCD/x'},
      ]);
    });

    testWidgets('a root the server refuses says so and moves nothing', (
      tester,
    ) async {
      final client = FakeServerCache(usage: overLimitEvictable)
        ..settingsError = StateError('not writable');
      await tester.pumpWidget(
        MaterialApp(
          home: ServerStorageScreen(
            client: client,
            roots: () async => const [],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '/root/nope');
      await tester.tap(find.text('Use this folder'));
      await tester.pumpAndSettle();

      expect(find.text(ServerStorageScreen.refusedMessage), findsOneWidget);
      expect(find.text('/data/cache/server'), findsWidgets);
    });
  });

  group('one device with no cacheSize, read by two screens', () {
    // The owner's box: nothing configured, so the server caps the cache at
    // what the volume can give above its floor. The storage screen reads
    // that cap and the diagnostics header reads the setting, which is two
    // different questions -- and while the header answered its one with
    // "no limit set" the app contradicted itself, denying a limit on one
    // screen and calling the cache over it in error red on the other.
    const ServerStorage nothingConfigured = ServerStorage(
      cacheDir: '/data/user/0/com.zond.xtremio/cache/server',
      cacheUsedBytes: 3000000000,
      cacheVolume: StorageVolume(
        path: '/data/user/0/com.zond.xtremio/cache/server',
        freeBytes: 223000000,
        totalBytes: 4000000000,
      ),
    );
    const CacheUsage cappedByTheDevice = CacheUsage(
      totalBytes: 3000000000,
      limitBytes: 2686000000,
      protectedBytes: 0,
      protectedFiles: 0,
    );

    test('the header names the setting rather than denying the limit', () {
      expect(nothingConfigured.cacheLimitBytes, isNull);
      expect(nothingConfigured.cacheLabel, '3.0 GB, no cacheSize set');
      expect(
        nothingConfigured.reportLines.first,
        isNot(contains('no limit set')),
        reason: 'there is a limit; the device is what set it',
      );
    });

    test('and the storage screen is the one that knows what it is', () {
      expect(cappedByTheDevice.overLimit, isTrue);
      expect(cappedByTheDevice.label, '3.0 GB of 2.7 GB limit');
      expect(
        nothingConfigured.overLimit,
        isFalse,
        reason: 'the setting is not what this cache is over',
      );
    });
  });
}
