import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/main.dart' as boot;

/// The server's settings, and every patch written to them.
class _FakeSettings implements ServerSettingsAccess {
  _FakeSettings(this.cacheRoot, {this.readFails = false});

  final String cacheRoot;
  final bool readFails;
  final List<Map<String, dynamic>> patches = [];

  @override
  Future<Map<String, dynamic>> settings() async {
    if (readFails) throw StateError('server not running');
    return {'cacheRoot': cacheRoot, 'cacheSize': 10000000000};
  }

  @override
  Future<Map<String, dynamic>> updateSettings(
    Map<String, dynamic> patch,
  ) async {
    patches.add(patch);
    return {'cacheRoot': patch['cacheRoot']};
  }
}

/// Where the embedded server puts torrent data when its settings name no
/// root of their own.
///
/// It is one root now, so this directory holds the streaming cache *and*
/// everything kept offline. On Android that rules out the app cache
/// directory, which the system reclaims whenever it wants room: a build
/// that defaulted there would hand every kept download to the reclaimer,
/// and there is nowhere else for one to be.
void main() {
  final Directory appCache = Directory('/data/user/0/com.zond.xtremio/cache');
  final Directory external = Directory(
    '/storage/emulated/0/Android/data/com.zond.xtremio/files',
  );

  test(
    'on Android it is the external files directory, never the cache',
    () async {
      expect(
        await boot.dataDirectory(
          isAndroid: true,
          externalFiles: () async => external,
          appCache: () async => appCache,
        ),
        external,
      );
    },
  );

  test('a device with no external storage falls back to the cache', () async {
    expect(
      await boot.dataDirectory(
        isAndroid: true,
        externalFiles: () async => null,
        appCache: () async => appCache,
      ),
      appCache,
      reason: 'a purgeable root still beats no server at all',
    );
  });

  group('moving an upgraded install off a purgeable root', migration);

  test('everywhere else the cache directory is the right place', () async {
    expect(
      await boot.dataDirectory(
        isAndroid: false,
        externalFiles: () async => external,
        appCache: () async => appCache,
      ),
      appCache,
      reason: 'nothing on a desktop reclaims it under the app',
    );
  });
}

/// What an upgraded Android install has to be got off, and what nothing
/// else may touch.
///
/// The directories are real, and the Android shape is built as Android
/// builds it: `/data/user/0/<pkg>` is a symlink to `/data/data/<pkg>`, so
/// the root the server persisted (canonical, resolved through the link) is
/// spelled differently from the cache directory `path_provider` answers.
/// A migration comparing the two strings as they come would decide that a
/// root inside the app's cache directory is not inside it, and leave every
/// upgraded device on the one directory the system reclaims.
void migration() {
  late Directory tmp;
  late Directory internal;
  late Directory purgeable;
  late Directory external;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xtremio-root');
    internal = await Directory('${tmp.path}/data/data/com.zond.xtremio/cache')
        .create(recursive: true);
    await Link('${tmp.path}/data/user/0')
        .create('${tmp.path}/data/data', recursive: true);
    purgeable = Directory('${tmp.path}/data/user/0/com.zond.xtremio/cache');
    external = await Directory(
      '${tmp.path}/storage/emulated/0/Android/data/com.zond.xtremio/files',
    ).create(recursive: true);
  });

  tearDown(() async => tmp.delete(recursive: true));

  test(
    'an install that came up on the app cache directory is moved off it',
    () async {
      // What every build before this one persisted at its first start, in the
      // spelling the server stores it in: resolved through the symlink.
      final server = _FakeSettings('${internal.path}/server');

      final moved = await boot.moveOffPurgeableRoot(
        server: server,
        wanted: '${external.path}/server',
        purgeable: purgeable,
        safe: external,
      );

      expect(moved, '${external.path}/server');
      expect(server.patches, [
        {'cacheRoot': '${external.path}/server'},
      ]);
    },
  );

  test('a root somebody chose is left exactly as it is', () async {
    final server = _FakeSettings('/media/torrents');

    expect(
      await boot.moveOffPurgeableRoot(
        server: server,
        wanted: '${external.path}/server',
        purgeable: purgeable,
        safe: external,
      ),
      isNull,
    );
    expect(server.patches, isEmpty, reason: 'nothing was written');
  });

  test('an install already on the safe root writes nothing', () async {
    final server = _FakeSettings('${external.path}/server');

    expect(
      await boot.moveOffPurgeableRoot(
        server: server,
        wanted: '${external.path}/server',
        purgeable: purgeable,
        safe: external,
      ),
      isNull,
      reason: 'it runs once, and after it there is nothing left to move',
    );
    expect(server.patches, isEmpty);
  });

  test('with nowhere safer to go the settings are not even read', () async {
    // Every desktop, and an Android device with no external storage at
    // all: `dataDirectory` answers the cache directory itself.
    final server = _FakeSettings('${internal.path}/server');

    expect(
      await boot.moveOffPurgeableRoot(
        server: server,
        wanted: '${internal.path}/server',
        purgeable: purgeable,
        safe: purgeable,
      ),
      isNull,
    );
    expect(server.patches, isEmpty);
  });

  test('a server that cannot be asked is left alone', () async {
    final server = _FakeSettings('', readFails: true);

    expect(
      await boot.moveOffPurgeableRoot(
        server: server,
        wanted: '${external.path}/server',
        purgeable: purgeable,
        safe: external,
      ),
      isNull,
    );
    expect(server.patches, isEmpty);
  });
}
