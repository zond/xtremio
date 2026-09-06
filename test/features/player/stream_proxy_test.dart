import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';

import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// Every stream reaches the player as a URL on our own server.
///
/// The player keeps nothing on disk any more, so a stream it fetched itself
/// would be the one kind of playback with no local copy anywhere -- and on
/// the owner's Chromecast that was the kind that filled the volume: a
/// 90-second RD/HTTP title left 928 MB in an mpv cache file with no
/// directory entry, and the server, which does have a cache it can bound
/// and sweep, was never in the path at all.
///
/// The shape asserted here is the one the server parses; that it really
/// serves it is `server/tests/proxy.rs` in the stream-server tree.
void main() {
  final server = Uri.parse('http://127.0.0.1:39661/');

  /// The target URL a `/proxy` URL was built for, read back the way the
  /// server reads it (`server/src/routes/proxy.rs`): everything up to the
  /// first `/` is a `&`-joined parameter segment whose `d=` is the origin,
  /// percent-decoded once; whatever path and query follow it are the
  /// target's own, byte for byte as they were written.
  ///
  /// Deliberately a re-implementation of the server's parse rather than a
  /// call to `Uri`: `Uri.pathSegments` and `Uri.queryParameters` both
  /// decode, and a test that decoded could not tell an escape that
  /// survived from one that did not.
  String targetOf(Uri proxied) {
    const marker = '/proxy/';
    final written = proxied.toString();
    final start = written.indexOf(marker);
    expect(start, isNonNegative, reason: 'not a proxy URL: $written');
    final segment = start + marker.length;
    var end = segment;
    while (end < written.length && written[end] != '/' && written[end] != '?') {
      end++;
    }
    final params = written.substring(segment, end).split('&');
    final origin = params.firstWhere(
      (param) => param.startsWith('d='),
      orElse: () => fail('no d= in the proxy segment of $written'),
    );
    return '${Uri.decodeComponent(origin.substring(2))}'
        '${written.substring(end)}';
  }

  group('a stream on somebody else\'s host', () {
    test('is handed to the player as a URL on our server', () {
      final proxied = proxiedThroughServer(
        Uri.parse('https://rd.example/dl/token/film.mkv'),
        serverBase: server,
      );

      expect(proxied.host, '127.0.0.1');
      expect(proxied.port, 39661);
      expect(proxied.pathSegments.first, 'proxy');
    });

    test('reaches the origin whole, path and query and all', () {
      // A signed link is signed over its query, so losing or reordering one
      // parameter is a 403 rather than a slow stream.
      final proxied = proxiedThroughServer(
        Uri.parse('https://rd.example/dl/tok/film.mkv?e=1699&sig=ab%2Fcd'),
        serverBase: server,
      );

      expect(
        targetOf(proxied),
        'https://rd.example/dl/tok/film.mkv?e=1699&sig=ab%2Fcd',
      );
    });

    test('keeps its file name where a demuxer can see it', () {
      // Deliberate, and the reason the whole URL is not simply folded into
      // the `d=` value: ffmpeg's format probing takes the extension as a
      // hint, and a log line with a name in it is worth reading.
      final proxied = proxiedThroughServer(
        Uri.parse('https://cdn.example/a/b/film.mkv'),
        serverBase: server,
      );

      expect(proxied.path, endsWith('/film.mkv'));
    });

    test('survives a path that is already percent-encoded', () {
      final proxied = proxiedThroughServer(
        Uri.parse('https://cdn.example/my%20film.mkv'),
        serverBase: server,
      );

      expect(targetOf(proxied), 'https://cdn.example/my%20film.mkv');
    });

    test('keeps the escapes that do not round-trip by accident', () {
      // `%20` above survives being decoded and re-encoded, so on its own it
      // proves nothing: a space is a space either way. These three do not.
      // `%2F` decoded is a path separator, `%3F` decoded starts a query and
      // `%23` decoded starts a fragment that takes the rest of the URL with
      // it -- which is what a debrid link's base64 signature and a file
      // named with a `#` actually run into.
      for (final path in ['a%2Fb/film.mkv', 'a%3Fb.mkv', 'a%23b.mkv']) {
        final proxied = proxiedThroughServer(
          Uri.parse('https://cdn.example/$path'),
          serverBase: server,
        );

        expect(targetOf(proxied), 'https://cdn.example/$path');
      }
    });

    test('is not taken apart by a target that has a d of its own', () {
      // The server used to read the *request's* `d` query parameter before
      // looking at the path, so a target carrying one answered 400 -- and a
      // `d` that happened to parse as a URL was fetched instead of the
      // target. The parameter belongs to the target and travels with its
      // query; nothing here escapes it away.
      final proxied = proxiedThroughServer(
        Uri.parse('https://cdn.example/film.mkv?d=1&t=2'),
        serverBase: server,
      );

      expect(targetOf(proxied), 'https://cdn.example/film.mkv?d=1&t=2');
    });

    test('drops the fragment, which no server was ever sent', () {
      final proxied = proxiedThroughServer(
        Uri.parse('https://cdn.example/film.mkv#t=90'),
        serverBase: server,
      );

      expect(targetOf(proxied), 'https://cdn.example/film.mkv');
    });

    test('keeps a non-default port and a userinfo-free authority', () {
      final proxied = proxiedThroughServer(
        Uri.parse('http://cdn.example:8080/film.mkv'),
        serverBase: server,
      );

      expect(targetOf(proxied), 'http://cdn.example:8080/film.mkv');
    });
  });

  group('what is left alone', () {
    test('a torrent the server is already serving', () {
      // Whatever port the embedded server bound: the profile says 11470 and
      // the server takes what it can get, so the port is no part of the
      // question.
      final url = Uri.parse('http://127.0.0.1:39661/abc123/0?buffer=large');

      expect(proxiedThroughServer(url, serverBase: server), url);
      expect(
        proxiedThroughServer(
          url,
          serverBase: Uri.parse('http://127.0.0.1:11470/'),
        ),
        url,
      );
    });

    test('a stream already on the server we would proxy through', () {
      // The same refusal as the loopback one above, reached by the other
      // rule: whatever base URL we are handed, a stream already on it is
      // one that server is serving, not one to hand back to it. In this
      // app the two rules always agree, because the base URL is always the
      // loopback embedded server.
      final base = Uri.parse('https://server.example.com/');
      final url = Uri.parse('https://server.example.com/abc123/0');

      expect(proxiedThroughServer(url, serverBase: base), url);
    });

    test('an offline file, and a magnet the core has not resolved', () {
      for (final url in [
        Uri.parse('file:///data/downloads/abc/film.mkv'),
        Uri.parse('magnet:?xt=urn:btih:abc123'),
      ]) {
        expect(proxiedThroughServer(url, serverBase: server), url);
      }
    });

    test('everything, when there is no server to proxy through', () {
      final url = Uri.parse('https://rd.example/film.mkv');

      expect(proxiedThroughServer(url, serverBase: null), url);
    });
  });

  group('what the player is told about seeking', () {
    test('a proxied stream is not promised the torrent reader\'s patience', () {
      // `force-seekable` says a seek the demuxer refuses should be made
      // anyway, and that is a claim about the *server's own* reader: it
      // waits for a cold offset and never refuses. The proxy relays a host
      // nobody here knows, so forcing would turn a refusal the viewer sees
      // into a bar sitting at a position no packet will arrive for.
      final proxied = proxiedThroughServer(
        Uri.parse('https://rd.example/film.mkv'),
        serverBase: server,
      );

      expect(MediaKitEngine.forcesSeekable(proxied), isFalse);
    });

    test('the server\'s own stream still is', () {
      expect(
        MediaKitEngine.forcesSeekable(
          Uri.parse('http://127.0.0.1:39661/abc123/0?buffer=normal'),
        ),
        isTrue,
      );
    });

    test('and so is a remote host, exactly as before', () {
      expect(
        MediaKitEngine.forcesSeekable(Uri.parse('https://rd.example/film.mkv')),
        isFalse,
      );
    });
  });

  group('the screen', () {
    /// The recorded torrent fixture rewritten into an addon's own HTTP
    /// stream: no info hash anywhere, and a `streaming_url` on a host that
    /// is not ours -- which is what stremio-core resolves for a debrid or
    /// direct-HTTP source.
    Map<String, dynamic> remoteStreamFixture(String url) {
      final fixture = loadPlayerFixture();
      final stream = <String, dynamic>{'url': url, 'name': 'Direct'};
      (fixture['selected'] as Map<String, dynamic>)['stream'] = stream;
      fixture['stream'] = {
        'type': 'Ready',
        'content': [
          {'stream': stream, 'streaming_url': url},
          stream,
        ],
      };
      return fixture;
    }

    testWidgets('opens a remote stream through the server, never direct', (
      tester,
    ) async {
      useWideViewport(tester);
      const remote = 'https://rd.example/dl/tok/film.mkv';
      final harness = PlayerHarness(player: remoteStreamFixture(remote));
      await harness.pump(tester);

      final opened = harness.engine.opened.single.$1;
      expect(opened.host, '127.0.0.1', reason: 'our own server, not theirs');
      expect(opened.pathSegments.first, 'proxy');
      expect(
        opened.toString(),
        contains(Uri.encodeComponent('https://rd.example')),
      );
      expect(opened.path, endsWith('/film.mkv'));
    });

    testWidgets('plays direct when this build runs no server of its own', (
      tester,
    ) async {
      // A build that started no embedded server at all -- which is not
      // what choosing a streaming server elsewhere does, since that leaves
      // the embedded one running and `CoreInitInfo.serverBaseUrl` naming
      // it, and those streams go through the proxy like anybody else's.
      // With nothing to proxy through the stream goes straight out, which
      // is what every build did before this.
      useWideViewport(tester);
      const remote = 'https://rd.example/dl/tok/film.mkv';
      final harness = PlayerHarness(
        player: remoteStreamFixture(remote),
        embeddedServer: false,
      );
      await harness.pump(tester);

      expect(harness.engine.opened.single.$1.toString(), remote);
    });

    testWidgets('opens a torrent on the server exactly as it always did', (
      tester,
    ) async {
      // The other half: a stream the server already serves must not be
      // wrapped in the server's proxy of itself.
      useWideViewport(tester);
      final harness = PlayerHarness();
      await harness.pump(tester);

      final opened = harness.engine.opened.single.$1;
      expect(opened.pathSegments.first, isNot('proxy'));
      expect(opened.queryParameters['buffer'], 'normal');
    });
  });
}
