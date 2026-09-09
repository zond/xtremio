import 'dart:io';
import 'dart:typed_data';

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
      await expectLater(server.backgroundTraffic(), throwsA(anything));
      await expectLater(
        server.streamNumbers(Uri.parse('https://origin.example/film.mkv')),
        throwsA(anything),
      );

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

      // ... the activity light's reading, dark on a server nothing has
      // asked anything of and judged over the server's own window ...
      final traffic = await server.backgroundTraffic();
      expect(traffic.active, isFalse);
      expect(traffic.downloading, isFalse);
      expect(traffic.uploading, isFalse);
      expect(traffic.playing, isFalse);
      expect(traffic.bytesDownloaded, 0);
      expect(traffic.bytesUploaded, 0);
      expect(traffic.windowSecs, 5);

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

      // ... and what this server holds of one playing stream, asked with
      // the URL a player was handed. A URL it does not hold is a complete
      // answer of nothing rather than an error: an addon's direct link is
      // playing perfectly well without us, and a panel over it must not
      // show a failure.
      expect(
        await server.streamNumbers(
          Uri.parse('https://origin.example/film.mkv'),
        ),
        isNull,
      );

      // Nor does the torrent above have rows yet, and for the sharper
      // reason: its magnet is still resolving, so there is no engine to
      // peek at and nothing of it on this device. **That absence is the
      // whole point.** A window of zero there would be this process
      // reporting a cache it has never looked in -- a claim about a past
      // it never saw -- where the truth is that it has not looked.
      expect(await server.streamNumbers(url.resolve('$_infoHash/0')), isNull);

      await server.stop();
      expect(server.baseUrl, isNull);
      await expectLater(server.settings(), throwsA(anything));
      await expectLater(
        server.streamNumbers(url.resolve('$_infoHash/0')),
        throwsA(anything),
      );
    },
  );

  test(
    'the numbers of a stream this server is proxying come back as numbers',
    () async {
      // Every other question here is answered with an absence, and an
      // absence is what a `null` on the way out looks like too: this is the
      // one that has the server really holding a stream, so the JSON it
      // sends comes back through the client as a reading somebody could
      // draw a row from.
      final tmp = await Directory.systemTemp.createTemp('xtremio-proxy-test-');
      const server = ServerClient();
      addTearDown(() async {
        await server.stop();
        await tmp.delete(recursive: true);
      });

      // Somebody else's host, which is the whole reason `/proxy` exists.
      // It answers one file with the three things that make a response one
      // the cache may file: a length, a validator, and a promise to answer
      // ranges.
      final film = Uint8List(8 * 1024 * 1024);
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp4')
          ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..headers.set(HttpHeaders.etagHeader, '"film"')
          ..headers.contentLength = film.length
          ..add(film);
        await request.response.close();
      });

      final url = await server.start(
        configDir: Directory('${tmp.path}/server'),
        cacheDir: Directory('${tmp.path}/cache/server'),
        port: 0,
      );

      // A cache this film does not fit in, because that is the condition
      // the window row reports on: where the budget covers the stream
      // nothing is bounding it, what is on the disk is whatever the
      // cleaner has not aged out yet -- a different quantity -- and the
      // server answers no window rather than calling that one. The
      // cleaner's pass is what publishes the budget, so it is run here
      // and awaited rather than waited for.
      await server.updateSettings({'cacheSize': 4 * 1024 * 1024});
      await server.cleanCacheNow();

      // The URL a player is handed for a stream that is not a torrent: the
      // origin escaped into `d=`, this player's token beside it, and the
      // file's own path and query on the outside -- the shape
      // `proxiedThroughServer` writes, spelled out here because it
      // (correctly) declines to wrap a loopback origin.
      final proxied = Uri.parse(
        '${url.origin}/proxy/'
        'd=${Uri.encodeComponent('http://127.0.0.1:${origin.port}')}'
        '&p=player-1/film.mp4?v=7',
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(proxied)).close();
      expect(response.statusCode, 200);
      var received = 0;
      await for (final bytes in response) {
        received += bytes.length;
      }
      expect(received, film.length);

      // The answer this path exists for, decoded off the wire and not an
      // absence: a window over a stream this server is holding, asked with
      // the URL the player was handed and nothing besides. That URL is the
      // whole of the question -- the query on it is the target's own, so it
      // is part of the stream's name, and the path alone names no stream at
      // all.
      final numbers = await server.streamNumbers(proxied);
      expect(numbers, isNotNull);
      final window = numbers!.window;
      expect(window, isNotNull);
      // What is on the disk is some of the film and never more than it.
      // Some of it, and not none: the whole film was read through this
      // route a moment ago, so a pair of zeroes here would be a decode of
      // an empty answer passing as a reading of a store that is holding
      // something. Which chunks are down at this instant is the cleaner's
      // business and not this call's, so nothing here counts them.
      expect(window!.behindBytes + window.aheadBytes, greaterThan(0));
      expect(
        window.behindBytes + window.aheadBytes,
        lessThanOrEqualTo(film.length),
      );
      // And no sharing row: a proxied response is relayed, never seeded,
      // so there is no committed set and no ratio to draw.
      expect(numbers.sharing, isNull);
    },
  );
}
