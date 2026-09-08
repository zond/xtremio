import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/main.dart' as boot;

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
