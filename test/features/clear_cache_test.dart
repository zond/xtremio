import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/diagnostics/clear_cache.dart';
import 'package:xtremio/features/diagnostics/server_storage_screen.dart';
import 'package:xtremio/features/settings/settings_screen.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../support/fake_core_client.dart';
import '../support/fake_server_cache.dart';
import '../support/fixtures.dart';
import '../support/tv.dart';

/// What a clear on a device that was playing answers.
const CacheClearReport _cleared = CacheClearReport(
  freed: 1200000000,
  stopped: 2,
  deleted: 640,
  total: 0,
);

/// Settings over [cache], on a television when [onTv].
Widget _settings(FakeServerCache cache, {bool onTv = false}) {
  final core = FakeCoreClient(
    state: {CoreField.ctx: loadCtxLoggedOutFixture()},
  );
  return DeviceScope(
    profile: onTv ? tv : DeviceProfile.fallback,
    child: CoreScope(
      client: core,
      child: MaterialApp(home: SettingsScreen(cache: cache)),
    ),
  );
}

/// Scrolls Settings to the "Clear the cache" row.
Future<Finder> _row(WidgetTester tester) async {
  final row = find.widgetWithText(ListTile, ClearCacheTile.title);
  await tester.scrollUntilVisible(
    row,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  return row;
}

void main() {
  testWidgets('Settings offers "Clear the cache" with the server, saying '
      'what it does, and a driver can read it', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_settings(FakeServerCache()));
    await tester.pumpAndSettle();
    await _row(tester);

    expect(find.text(ClearCacheTile.title), findsOneWidget);
    expect(
      find.text(
        'Stops what is streaming and deletes everything cached; downloads '
        'you kept stay',
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp('^Clear the cache')), findsOneWidget);
    // In the Streaming server section, below Server storage.
    expect(
      tester.getTopLeft(find.text(ClearCacheTile.title)).dy,
      greaterThan(tester.getTopLeft(find.text('Server storage')).dy),
    );
    semantics.dispose();
  });

  testWidgets('it asks first, and Cancel clears nothing', (tester) async {
    final cache = FakeServerCache(clearResult: _cleared);
    await tester.pumpWidget(_settings(cache));
    await tester.pumpAndSettle();
    await tester.tap(await _row(tester));
    await tester.pumpAndSettle();

    expect(find.text('Clear the cache?'), findsOneWidget);
    expect(
      find.text(
        'Stops what is streaming and deletes everything cached. Downloads '
        'you kept stay.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(ClearCacheDialog.cancelLabel));
    await tester.pumpAndSettle();
    expect(find.byType(ClearCacheDialog), findsNothing);
    expect(cache.clears, 0);
  });

  testWidgets('Clear clears and says what it freed and stopped', (
    tester,
  ) async {
    final cache = FakeServerCache(clearResult: _cleared);
    await tester.pumpWidget(_settings(cache));
    await tester.pumpAndSettle();
    await tester.tap(await _row(tester));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ClearCacheDialog.clearLabel));
    await tester.pumpAndSettle();

    expect(cache.clears, 1);
    expect(cache.cleans, 0, reason: 'a clear is not a clean');
    expect(find.text('Freed 1.2 GB, stopped 2 torrents'), findsOneWidget);
  });

  testWidgets('one torrent is one torrent, and a failed clear says so', (
    tester,
  ) async {
    expect(
      clearCacheMessage(
        const CacheClearReport(freed: 0, stopped: 1, deleted: 0, total: 0),
      ),
      'Freed 0 B, stopped 1 torrent',
    );
    final cache = FakeServerCache(clearError: StateError('not running'));
    await tester.pumpWidget(_settings(cache));
    await tester.pumpAndSettle();
    await tester.tap(await _row(tester));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ClearCacheDialog.clearLabel));
    await tester.pumpAndSettle();
    expect(find.text('The cache could not be cleared.'), findsOneWidget);
  });

  testWidgets('on a television the row is a stop and the dialog opens on '
      'Cancel', (tester) async {
    final cache = FakeServerCache(clearResult: _cleared);
    await tester.pumpWidget(_settings(cache, onTv: true));
    await tester.pumpAndSettle();
    final row = await _row(tester);
    final tile = tester.widget<ListTile>(row);
    expect(tile.onTap, isNotNull, reason: 'a row with no onTap is no stop');

    await tester.tap(row);
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    expect(
      find.descendant(
        of: find.byWidget(focused!.widget),
        matching: find.text(ClearCacheDialog.cancelLabel),
      ),
      findsOneWidget,
      reason: 'a press still in flight from the remote must not clear',
    );
    // Select on what has focus is Cancel.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(ClearCacheDialog), findsNothing);
    expect(cache.clears, 0);
  });

  testWidgets('Server storage offers the clear beside the clean, and reads '
      'the numbers again after it', (tester) async {
    final cache = FakeServerCache(
      usage: overLimitNothingEvictable,
      clearResult: _cleared,
    );
    await tester.pumpWidget(
      MaterialApp(home: ServerStorageScreen(client: cache)),
    );
    await tester.pumpAndSettle();
    final reads = cache.reads;

    expect(find.text('Clean cache now'), findsOneWidget);
    await tester.tap(find.text(ClearCacheTile.title));
    await tester.pumpAndSettle();
    expect(find.byType(ClearCacheDialog), findsOneWidget);
    await tester.tap(find.text(ClearCacheDialog.clearLabel));
    await tester.pumpAndSettle();

    expect(cache.clears, 1);
    expect(cache.cleans, 0);
    expect(cache.reads, reads + 1, reason: 'the numbers after the clear');
    expect(find.text('Freed 1.2 GB, stopped 2 torrents'), findsOneWidget);
  });
}
