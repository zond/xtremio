import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';

import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// Every stream reaches the player as a URL on our own server.
///
/// The player keeps nothing on disk (docs/ARCHITECTURE.md, "Streams, the
/// proxy and the cache"), so a stream it fetched itself would be the one
/// kind of playback with no local copy anywhere, and none of the server's
/// bounded, swept cache in the path at all.
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
      // Reading the *request's* own `d` query parameter before the path
      // would answer 400 for a target carrying one -- or worse, fetch
      // whatever `d` happens to parse as instead of the target. The
      // parameter belongs to the target and travels with its query;
      // nothing here escapes it away.
      final proxied = proxiedThroughServer(
        Uri.parse('https://cdn.example/film.mkv?d=1&t=2'),
        serverBase: server,
      );

      expect(targetOf(proxied), 'https://cdn.example/film.mkv?d=1&t=2');
    });

    test("carries the player's token, and only in the proxy's own half", () {
      // `p=` joins `d=` in the parameter segment, which is the half the
      // server keeps: it is what `closeProxyStreams` addresses, and it
      // never travels to the origin. Asserted from both sides -- the token
      // is in the URL, and the target read back out of it is untouched.
      final proxied = proxiedThroughServer(
        Uri.parse('https://rd.example/dl/tok/film.mkv?e=1699'),
        serverBase: server,
        playerToken: 'player-7',
      );

      expect(proxied.toString(), contains('&p=player-7/'));
      expect(targetOf(proxied), 'https://rd.example/dl/tok/film.mkv?e=1699');
    });

    test('escapes a token that would otherwise end the segment', () {
      // The segment is `&`-joined and read with `form_urlencoded`, so a
      // token holding `&`, `=` or a `/` would silently become another
      // parameter or the start of the path. Nothing in this app mints one
      // like that; the escaping is what makes that a choice rather than a
      // constraint.
      final proxied = proxiedThroughServer(
        Uri.parse('https://rd.example/film.mkv'),
        serverBase: server,
        playerToken: 'a&b=c/d',
      );

      expect(proxied.toString(), contains('&p=a%26b%3Dc%2Fd/film.mkv'));
      expect(targetOf(proxied), 'https://rd.example/film.mkv');
    });

    test('is unmarked when no token was minted', () {
      final proxied = proxiedThroughServer(
        Uri.parse('https://rd.example/film.mkv'),
        serverBase: server,
      );

      expect(proxied.toString(), isNot(contains('p=')));
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

    test('any loopback URL, by any name for this device', () {
      // Every loopback URL is the embedded server's -- there is no other
      // server on this device -- so neither the name nor the port makes
      // one worth wrapping in the server's proxy of itself.
      for (final url in [
        Uri.parse('http://localhost:39661/drive/stream?id=f'),
        Uri.parse('http://[::1]:39661/downloads/k/stream'),
        Uri.parse('http://127.0.0.1:11470/abc123/0'),
      ]) {
        expect(proxiedThroughServer(url, serverBase: server), url);
      }
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
      expect(
        harness.mediaIds.registered,
        isEmpty,
        reason: 'only a torrent is played by id, for now',
      );
    });

    testWidgets('plays direct when this build runs no server of its own', (
      tester,
    ) async {
      // A build that started no embedded server at all
      // (`CoreInitInfo.serverBaseUrl` null). With nothing to proxy
      // through, the stream goes straight out.
      useWideViewport(tester);
      const remote = 'https://rd.example/dl/tok/film.mkv';
      final harness = PlayerHarness(
        player: remoteStreamFixture(remote),
        embeddedServer: false,
      );
      await harness.pump(tester);

      expect(harness.engine.opened.single.$1.toString(), remote);
    });

    testWidgets('plays a torrent by its media id, not by a URL', (
      tester,
    ) async {
      // The other half: a stream the server already serves is registered
      // with it and read through the `xtremio` protocol -- not wrapped in
      // the server's proxy of itself, and not fetched over HTTP at all.
      useWideViewport(tester);
      final harness = PlayerHarness();
      await harness.pump(tester);

      final published = PlayerState.fromJson(
        harness.core.stateOf(CoreField.player) ?? const {},
      ).streamingUrl;
      expect(harness.mediaIds.registered, [published]);
      expect(harness.mediaIds.resolved, ['m1']);
      expect(harness.engine.opened.single.$1, Uri.parse('xtremio://m1'));
      final play = harness.mediaIds.plays.single;
      expect(play.id, 'm1');
      expect(play.buffer, 'normal');
      // This screen's player token, which makes the reads the viewer's
      // play session: the install's viewer id, then the screen's number.
      expect(play.token, matches(RegExp(r'^[0-9a-f]{16}\.\d+$')));
    });

    testWidgets('leaves a torrent on its URL in a build with no server', (
      tester,
    ) async {
      useWideViewport(tester);
      final harness = PlayerHarness(embeddedServer: false);
      await harness.pump(tester);

      final opened = harness.engine.opened.single.$1;
      expect(opened.isScheme('http'), isTrue, reason: '$opened');
      expect(opened.pathSegments.first, isNot('proxy'));
      expect(opened.queryParameters['buffer'], 'normal');
      expect(harness.mediaIds.registered, isEmpty);
    });
  });

  group('what counts as the embedded server', () {
    test('any name for this device, and nothing else', () {
      for (final host in ['127.0.0.1', '127.0.0.2', 'localhost', '::1']) {
        expect(isEmbeddedServerHost(host), isTrue, reason: host);
      }
      for (final host in ['192.168.7.20', 'rd.example', '']) {
        expect(isEmbeddedServerHost(host), isFalse, reason: host);
      }
    });
  });
}
