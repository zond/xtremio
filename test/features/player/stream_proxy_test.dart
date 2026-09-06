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
  /// server reads it: the `d=` segment percent-decoded, then whatever path
  /// and query follow it, exactly as they were written.
  String targetOf(Uri proxied) {
    const marker = '/proxy/d=';
    final written = proxied.toString();
    final start = written.indexOf(marker);
    expect(start, isNonNegative, reason: 'not a proxy URL: $written');
    final origin = start + marker.length;
    var end = origin;
    while (end < written.length && written[end] != '/' && written[end] != '?') {
      end++;
    }
    return '${Uri.decodeComponent(written.substring(origin, end))}'
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

    test('a stream on a configured remote streaming server', () {
      final remote = Uri.parse('https://server.example.com/');
      final url = Uri.parse('https://server.example.com/abc123/0');

      expect(proxiedThroughServer(url, serverBase: remote), url);
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
      // A viewer pointed at a streaming server somewhere else, or an
      // embedded one that never came up. Proxying through a server that is
      // not on this device would fetch the film over the internet twice for
      // a cache no cleaner here can see, so the stream goes straight out --
      // which is what every build did before this.
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
