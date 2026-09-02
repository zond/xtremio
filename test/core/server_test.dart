import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/server_client.dart';

import '../support/rust_lib.dart';

/// A well-known public-domain torrent (Night of the Living Dead); never
/// downloaded here, the stats call only creates its engine.
const _infoHash = '11ea02584fa6351956f35671962ab46354d99060';

void main() {
  setUpAll(initRustForTests);

  test(
    'embedded server starts on an ephemeral port, answers over FFI, and stops',
    () async {
      final tmp = await Directory.systemTemp.createTemp('xtremio-server-test-');
      const server = ServerClient();
      addTearDown(() async {
        await server.stop();
        await tmp.delete(recursive: true);
      });

      expect(server.baseUrl, isNull);
      await expectLater(server.settings(), throwsA(anything));

      final url = await server.start(
        configDir: Directory('${tmp.path}/server'),
        cacheDir: Directory('${tmp.path}/cache/server'),
        port: 0,
      );
      expect(url.scheme, 'http');
      expect(url.host, '127.0.0.1');
      expect(url.port, isNot(0));
      expect(server.baseUrl, url);

      // The control API, without HTTP: settings read and patched (the
      // patch is validated and merged like POST /settings would) ...
      final settings = await server.settings();
      expect(settings['btMaxConnections'], isA<int>());
      expect(settings.containsKey('cacheSize'), isTrue);
      final patched = await server.updateSettings({'btMaxConnections': 77});
      expect(patched['btMaxConnections'], 77);
      expect((await server.settings())['btMaxConnections'], 77);

      // ... and a torrent's stats, which create the engine and report the
      // metadata phase at once, per-file included; a negative index is
      // refused.
      final stats = await server.torrentStats(
        infoHash: _infoHash,
        trackers: const ['udp://tracker.opentrackr.org:1337/announce'],
      );
      expect(stats['infoHash'], _infoHash);
      expect(stats['phase'], 'resolvingMetadata');
      final perFile = await server.torrentStats(
        infoHash: _infoHash,
        fileIdx: 0,
      );
      expect(perFile['phase'], 'resolvingMetadata');
      await expectLater(
        server.torrentStats(infoHash: _infoHash, fileIdx: -1),
        throwsA(predicate((e) => e.toString().contains('file index'))),
      );

      await server.stop();
      expect(server.baseUrl, isNull);
      await expectLater(server.settings(), throwsA(anything));
    },
  );
}
