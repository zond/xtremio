import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/diagnostics/server_storage_screen.dart';

/// [ServerCacheControl] for widget tests: answers with what the test put in
/// it and counts what it was asked -- there is no restart call left to
/// record, since cleaning no longer needs one.
class FakeServerCache implements ServerCacheControl {
  FakeServerCache({
    this.usage,
    this.usageError,
    this.cleanResult,
    this.cleanError,
  });

  CacheUsage? usage;
  Object? usageError;
  EvictionReport? cleanResult;
  Object? cleanError;
  int reads = 0;
  int cleans = 0;

  @override
  Future<CacheUsage> cacheUsage() async {
    reads++;
    final error = usageError;
    if (error != null) throw error;
    return usage!;
  }

  @override
  Future<EvictionReport> cleanCacheNow() async {
    cleans++;
    final error = cleanError;
    if (error != null) throw error;
    return cleanResult!;
  }
}

/// A cache well past its limit, with nothing protected -- a clean would
/// reclaim all of it.
const CacheUsage overLimitEvictable = CacheUsage(
  totalBytes: 17000000000,
  limitBytes: 10000000000,
  protectedBytes: 0,
  protectedFiles: 0,
);

/// A cache over its limit where everything left is a live stream or a kept
/// download: cleaning cannot help.
const CacheUsage overLimitNothingEvictable = CacheUsage(
  totalBytes: 12000000000,
  limitBytes: 10000000000,
  protectedBytes: 12000000000,
  protectedFiles: 3,
);

void main() {
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
      reason: 'a cleaner reclaiming nothing is the thing to notice',
    );
    expect(client.cleans, 0, reason: 'nothing was asked of the server yet');
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
