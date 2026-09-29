import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/local/folder_access.dart';

import '../support/fake_prefs_client.dart';

/// macOS's way back into a chosen folder after a restart: a bookmark taken
/// when the folder is picked, opened before a scan, renewed when stale.
/// The Swift half (`MainFlutterWindow.swift`) is built by the macOS job.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('xtremio/folder_access');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<AppPrefs> prefs([FakePrefsClient? client]) async {
    final prefs = AppPrefs(client: client ?? FakePrefsClient());
    addTearDown(prefs.dispose);
    await prefs.load();
    return prefs;
  }

  test('a picked folder is bookmarked and the bookmark kept across a '
      'restart; a folder taken off forgets it', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'bookmark');
      return 'bm:${call.arguments['path']}';
    });
    final client = FakePrefsClient();
    final p = await prefs(client);
    final access = MacFolderAccess(prefs: p);
    await access.remember('/Users/me/Films');
    await access.remember('/Volumes/Disk/Series');

    final again = await prefs(client);
    expect(again.localFolderBookmarks, {
      '/Users/me/Films': 'bm:/Users/me/Films',
      '/Volumes/Disk/Series': 'bm:/Volumes/Disk/Series',
    });

    await MacFolderAccess(prefs: again).forget('/Users/me/Films');
    expect(again.localFolderBookmarks.keys, ['/Volumes/Disk/Series']);
  });

  test('opening asks once per folder per run, renews a stale bookmark, '
      'and passes over one that no longer opens', () async {
    final opened = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final bookmark = call.arguments['bookmark'] as String;
      opened.add(bookmark);
      return switch (bookmark) {
        'bm:a' => {'path': '/a', 'bookmark': 'bm:a'},
        'bm:b' => {'path': '/b', 'bookmark': 'bm:b-fresh'},
        _ => throw PlatformException(code: 'open'),
      };
    });
    final p = await prefs();
    await p.setLocalFolderBookmarks({'/a': 'bm:a', '/b': 'bm:b', '/c': 'bm:c'});
    final access = MacFolderAccess(prefs: p);

    await access.open();
    expect(opened, ['bm:a', 'bm:b', 'bm:c']);
    expect(p.localFolderBookmarks, {
      '/a': 'bm:a',
      '/b': 'bm:b-fresh',
      '/c': 'bm:c',
    });

    await access.open();
    expect(
      opened,
      ['bm:a', 'bm:b', 'bm:c', 'bm:c'],
      reason:
          'only the '
          'one that did not open is tried again',
    );
  });

  test('a folder the system will not bookmark is still added, for this '
      'run', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'bookmark'),
    );
    final p = await prefs();
    await MacFolderAccess(prefs: p).remember('/x');
    expect(p.localFolderBookmarks, isEmpty);
  });
}
