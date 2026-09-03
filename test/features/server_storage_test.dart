import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/diagnostics/server_storage_screen.dart';

/// [ServerCacheControl] for widget tests: answers with what the test put in
/// it and records the one call that would stop a real server.
class FakeServerCache implements ServerCacheControl {
  FakeServerCache({this.report, this.error});

  ServerStorage? report;
  Object? error;
  int reads = 0;
  int cleans = 0;

  @override
  Future<ServerStorage> storage() async {
    reads++;
    final error = this.error;
    if (error != null) throw error;
    return report!;
  }

  @override
  Future<Uri> cleanCache() async {
    cleans++;
    return Uri.parse('http://127.0.0.1:11470/');
  }
}

/// The device the owner's failure happened on: a cache well past its limit
/// on a volume with almost nothing left.
ServerStorage fullDevice() => const ServerStorage(
  cacheDir: '/data/user/0/com.zond.xtremio/cache/server',
  cacheUsedBytes: 17000000000,
  cacheLimitBytes: 10737418240,
  cacheVolume: StorageVolume(
    path: '/data/user/0/com.zond.xtremio/cache/server',
    freeBytes: 402653184,
    totalBytes: 57000000000,
  ),
);

void main() {
  testWidgets('says what the cache costs and that it is over its limit', (
    tester,
  ) async {
    final client = FakeServerCache(report: fullDevice());
    await tester.pumpWidget(
      MaterialApp(home: ServerStorageScreen(client: client)),
    );
    await tester.pumpAndSettle();

    expect(find.text('17.0 GB of 10.7 GB limit'), findsOneWidget);
    expect(find.text('403 MB free of 57.0 GB'), findsOneWidget);
    expect(
      find.textContaining('Over its limit'),
      findsOneWidget,
      reason: 'a cleaner reclaiming nothing is the thing to notice',
    );
  });

  testWidgets('cleaning asks first, because it stops the server', (
    tester,
  ) async {
    final client = FakeServerCache(report: fullDevice());
    await tester.pumpWidget(
      MaterialApp(home: ServerStorageScreen(client: client)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clean cache now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Anything playing will stop'), findsOneWidget);

    // Cancelled: nothing was asked of the server.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(client.cleans, 0);

    await tester.tap(find.text('Clean cache now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart and clean'));
    await tester.pumpAndSettle();
    expect(client.cleans, 1);
    // And the numbers are read again afterwards.
    expect(client.reads, 2);
    expect(find.textContaining('sweeping its cache'), findsOneWidget);
  });

  testWidgets('a server that is not running says so and cleans nothing', (
    tester,
  ) async {
    final client = FakeServerCache(error: StateError('not running'));
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
}
