import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/diagnostics/diagnostics_report.dart';
import 'package:xtremio/features/diagnostics/diagnostics_screen.dart';

import '../support/diagnostics_capture.dart';
import '../support/fake_diagnostics_client.dart';

/// The in-app diagnostics: what the core's log ring says, what it must
/// never say, and the copy button that ships in release builds.
void main() {
  group('redactSecrets', () {
    test('scrubs the embedded server\'s bearer token', () {
      // The one line this whole feature must never produce: a request the
      // server logged with the token the app's control calls carry.
      const token = 'V3ry-S3cret_token.value~with+padding/AAAA=';
      const line =
          '2026-09-03T15:04:19.517Z ERROR stream_server: unhandled request '
          'headers=authorization=Bearer $token, accept=*/*';
      final redacted = redactSecrets(line);
      expect(redacted, isNot(contains(token)));
      expect(redacted, isNot(contains('Bearer')));
      expect(redacted, contains('authorization=<redacted>'));
      // The rest of the line survives: a scrub that ate the context would
      // make the log useless.
      expect(redacted, contains('unhandled request'));
      expect(redacted, contains('accept=*/*'));

      // A quoted header, and a bearer token with no header around it.
      expect(
        redactSecrets('{"Authorization": "Bearer $token"}'),
        '{"Authorization": "<redacted>"}',
      );
      expect(
        redactSecrets('sending Bearer $token upstream'),
        'sending Bearer <redacted> upstream',
      );
    });

    test('scrubs auth keys, passwords and other named secrets', () {
      // stremio-core's session key, as it appears in `ctx.profile.auth`.
      expect(
        redactSecrets('{"auth":{"key":"abc123","user":{"email":"a@b.c"}}}'),
        contains('"key":"<redacted>"'),
      );
      expect(redactSecrets('{"key":"abc123"}'), isNot(contains('abc123')));
      // An Authenticate action's password, and an addon's API key.
      expect(
        redactSecrets('Authenticate password=hunter2 email=a@b.c'),
        'Authenticate password=<redacted> email=a@b.c',
      );
      expect(
        redactSecrets('GET /catalog?apiKey=DEADBEEF0011&skip=100'),
        'GET /catalog?apiKey=<redacted>&skip=100',
      );
      expect(
        redactSecrets('auth_token: abc.def.ghi'),
        'auth_token: <redacted>',
      );
      expect(
        redactSecrets('key=0123456789abcdef0123'),
        'key=<redacted>',
        reason: 'a long token-shaped value named key is treated as one',
      );
      expect(
        redactSecrets('re-pinned key=tt0032138:1:2'),
        're-pinned key=tt0032138:1:2',
        reason: 'a download registry key is not a secret and is worth having',
      );
    });

    test('scrubs the path of an addon manifest URL, and URL credentials', () {
      // A debrid key rides in the path of a configured addon's manifest.
      // An http(s) one goes down to its origin with every other URL on
      // somebody else's host; the manifest rule is still what catches a
      // scheme the URL pass does not read.
      expect(
        redactSecrets('addon https://tor.example.com/DEBRIDKEY/manifest.json'),
        'addon https://tor.example.com/…',
      );
      expect(
        redactSecrets('stremio://x.io/a/b/manifest.json opened'),
        'stremio://x.io/<redacted>/manifest.json opened',
      );
      // The host is what names the addon in a report, and it stays.
      expect(
        redactSecrets('https://v3-cinemeta.strem.io/manifest.json'),
        'https://v3-cinemeta.strem.io/…',
      );
      expect(
        redactSecrets('fetch https://user:pass@host/x'),
        'fetch https://host/…',
      );
    });

    test('reduces a URL on somebody else\'s host to its origin', () {
      // Lines the Dart side never composed: the Rust half writes the
      // archive and proxy URLs it was given, a debrid link's token signed
      // into the path. And lines written whole under Verbose logging are
      // still in the ring after it is turned off.
      const line =
          'WARN stream_server::routes::archive: fetch failed '
          'url=https://xx12.download.real-debrid.com/d/RDSIGNEDTOKEN0123/Movie.rar '
          'proxy=http://127.0.0.1:11470/proxy/d=https%3A%2F%2Fcomet.example'
          '&p=PLAYERTOKEN/CONFIGKEY/playback/abc';
      final redacted = redactSecrets(line);
      expect(
        redacted,
        'WARN stream_server::routes::archive: fetch failed '
        'url=https://xx12.download.real-debrid.com/… '
        'proxy=http://127.0.0.1:11470/proxy/d=comet.example/…',
      );
      // The scrub is the scrub whatever the switch says: a report asked
      // for redacted while Verbose logging is on is redacted too.
      addTearDown(() => DiagnosticsLog.unredacted = false);
      DiagnosticsLog.unredacted = true;
      expect(redactSecrets(line), redacted);
    });

    test('leaves a field that holds nothing, and its punctuation, alone', () {
      // Both of these came out of a real report. `Url`'s own `Debug` prints
      // every field, so an absent password reads `password: None` -- and a
      // report that blanks it says a password was there.
      const url =
          'INFO xtremio_core::core: stremio-core runtime started '
          'server_base_url=Some(Url { scheme: "http", username: "", '
          'password: None, host: Some(Ipv4(127.0.0.1)), port: Some(11470) })';
      expect(redactSecrets(url), url);
      expect(redactSecrets('{"key":""}'), '{"key":""}');
      expect(redactSecrets('auth_token=null'), 'auth_token=null');

      // A header named in prose, with a placeholder for the value: the
      // whole point of the line is that there is no token in it, and the
      // closing backtick is not part of any value.
      const prose =
          'INFO stream_server: control API requires '
          '`Authorization: Bearer <token>`';
      expect(redactSecrets(prose), prose);
      // The same shape with a real value behind it still goes, backtick and
      // all still standing.
      expect(
        redactSecrets('requires `Authorization: Bearer s3cret-value` header'),
        'requires `Authorization: <redacted>` header',
      );
    });

    test('leaves the diagnostics worth having alone', () {
      const line =
          '2026-09-03T15:04:19.484Z  INFO xtremio_core::server: embedded '
          'stream-server started url=http://127.0.0.1:11470/';
      expect(redactSecrets(line), line);
      const failing =
          'Failed to open http://127.0.0.1:11470/'
          'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c/-1';
      expect(redactSecrets(failing), failing);
    });
  });

  test('the build a person types stamps the header', () {
    // `app: unknown` is what a plain `flutter build` produces, and it is
    // the one line saying which build a report is about. The Makefile is
    // the build that passes the two defines this file reads; renaming
    // either without the other would silently bring the `unknown` back.
    final makefile = File('Makefile').readAsStringSync();
    expect(makefile, contains('--dart-define=XTREMIO_VERSION='));
    expect(makefile, contains('--dart-define=XTREMIO_GIT_COMMIT='));
    for (final target in ['apk:', 'apk-split:', 'linux:', 'run:']) {
      expect(
        makefile,
        contains(target),
        reason: 'every documented build stamps the header',
      );
    }
  });

  group('describeAndroidOs', () {
    test('says the release, the API level and the hardware', () {
      // `Platform.operatingSystemVersion` on Android is the build
      // fingerprint ("W1VVS36H.7-108-8-6"), which names none of the three
      // -- and the hardware is what decides whether a codec is decoded on
      // a chip or on the CPU.
      expect(
        describeAndroidOs({
          'release': '14',
          'sdkInt': 34,
          'model': 'Pixel 7',
          'manufacturer': 'Google',
        }),
        'Android 14 (API 34) · Google Pixel 7',
      );
      // A model that already names its maker does not say it twice.
      expect(
        describeAndroidOs({
          'release': '11',
          'sdkInt': 30,
          'model': 'Nokia X20',
          'manufacturer': 'Nokia',
        }),
        'Android 11 (API 30) · Nokia X20',
      );
      // What is missing is left out, never written as a blank or an
      // invented "unknown".
      expect(describeAndroidOs({'sdkInt': 33}), 'Android (API 33)');
      expect(
        describeAndroidOs({'release': '10', 'model': 'sdk_gphone64_x86_64'}),
        'Android 10 · sdk_gphone64_x86_64',
      );
      expect(describeAndroidOs(const {}), 'Android');
    });
  });

  group('DiagnosticsLog', () {
    test('drops everything when nothing is listening', () {
      DiagnosticsLog.sink = null;
      DiagnosticsLog.reset();
      // A widget test that arranged nothing must not reach FFI, and an app
      // whose core is not up yet must not throw over a log line.
      expect(() => DiagnosticsLog.info('player', 'open'), returnsNormally);
    });

    test('counts a line that repeats instead of writing it again', () {
      final lines = captureDiagnostics();
      DiagnosticsLog.info('player', 'stalled');
      DiagnosticsLog.info('player', 'stalled');
      DiagnosticsLog.info('player', 'stalled');
      DiagnosticsLog.error('player', 'gave up');
      expect(lines, [
        'info player stalled',
        'info player last line repeated 2 times',
        'error player gave up',
      ]);
    });

    test('writes URLs whole while Verbose logging is on', () {
      // Verbose logging is for chasing a problem, and a redacted stream URL
      // is the thing that could not be chased: the RD stream mpv could not
      // recognise could not be fetched again. The switch says so.
      addTearDown(() => DiagnosticsLog.unredacted = false);
      final comet = Uri.parse(
        'http://127.0.0.1:46503/proxy/d=https%3A%2F%2Fcomet.example'
        '&p=tok/CONFIG/playback/abc?apiKey=k',
      );
      DiagnosticsLog.unredacted = true;
      expect(DiagnosticsLog.url(comet), comet.toString());
      final lines = captureDiagnostics();
      DiagnosticsLog.info('player', 'open $comet');
      expect(lines, ['info player open $comet']);

      DiagnosticsLog.unredacted = false;
      expect(
        DiagnosticsLog.url(comet),
        'http://127.0.0.1:46503/proxy/d=comet.example/…',
        reason: 'and redacted again once it is off',
      );
    });

    test('writes a URL without its query or its credentials', () {
      // The embedded server's own URL is worth having whole; an addon's is
      // where a key rides, and it rides in the query -- or in the path,
      // which is why a path on somebody else's host goes too.
      expect(
        DiagnosticsLog.url(Uri.parse('http://127.0.0.1:11470/abc123/-1?tr=x')),
        'http://127.0.0.1:11470/abc123/-1?…',
      );
      expect(
        DiagnosticsLog.url(Uri.parse('https://user:pw@host/path?apiKey=k')),
        'https://host/…?…',
      );
      expect(DiagnosticsLog.url(Uri.parse('https://host')), 'https://host');
      expect(
        DiagnosticsLog.url(Uri.parse('file:///home/someone/Videos/ep.mkv')),
        'file://…/ep.mkv',
      );
    });

    test('keeps the path only where the path is ours', () {
      addTearDown(DiagnosticsLog.reset);
      // The LAN listener's address, as a receiver is handed it: the same
      // `/{infoHash}/{fileIdx}` the server serves over loopback.
      DiagnosticsLog.noteOwnServer(Uri.parse('http://192.168.1.20:39271/'));
      DiagnosticsLog.noteOwnServer(Uri.parse('http://[fd00::7]:39271/'));
      expect(
        DiagnosticsLog.url(Uri.parse('http://192.168.1.20:39271/abc123/0')),
        'http://192.168.1.20:39271/abc123/0',
      );
      expect(
        DiagnosticsLog.url(Uri.parse('http://[fd00::7]:39271/abc123/0')),
        'http://[fd00::7]:39271/abc123/0',
      );
      // A private address is not ours for being private: an addon hosted
      // on the viewer's own LAN carries its config -- debrid key and all --
      // in its path. Nor is another port on our own listener's host.
      expect(
        DiagnosticsLog.url(
          Uri.parse('http://192.168.1.5:7000/realdebrid=RDKEY/stream/x.json'),
        ),
        'http://192.168.1.5:7000/…',
      );
      expect(
        DiagnosticsLog.url(Uri.parse('http://192.168.1.20:8080/CONFIG/x')),
        'http://192.168.1.20:8080/…',
      );
      expect(
        DiagnosticsLog.url(Uri.parse('http://10.0.0.7:39271/abc123/0')),
        'http://10.0.0.7:39271/…',
      );
      // A debrid host signs its token into the path; Torrentio puts the
      // debrid API key there. Neither is a path this app wrote.
      expect(
        DiagnosticsLog.url(
          Uri.parse(
            'https://xx12.download.real-debrid.com/d/ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCD/Some.Movie.2024.1080p.mkv',
          ),
        ),
        'https://xx12.download.real-debrid.com/…',
      );
      expect(
        DiagnosticsLog.url(
          Uri.parse(
            'https://torrentio.strem.fun/realdebrid/RDAPIKEY0123456789/abc123/null/0/Movie.mkv',
          ),
        ),
        'https://torrentio.strem.fun/…',
      );
      // 172.32.x is not private, whatever it looks like.
      expect(
        DiagnosticsLog.url(Uri.parse('http://172.32.0.1/abc123/0')),
        'http://172.32.0.1/…',
      );
    });

    test('a proxied stream keeps the target host and nothing else of it', () {
      // The exact chain playback runs: a debrid link through
      // `proxiedThroughServer`, then into the open line. What used to come
      // out was the whole thing -- debrid token, player token and file.
      final proxied = proxiedThroughServer(
        Uri.parse(
          'https://xx12.download.real-debrid.com/d/ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCD/Some.Movie.2024.1080p.mkv?token=QUERYTOKENabc',
        ),
        serverBase: Uri.parse('http://127.0.0.1:11470'),
        playerToken: 'PLAYERTOKEN-xyz',
      );
      expect(proxied.path, startsWith('/proxy/d='));
      final written = DiagnosticsLog.url(proxied);
      expect(
        written,
        'http://127.0.0.1:11470/proxy/d=xx12.download.real-debrid.com/…',
      );
      expect(written, isNot(contains('PLAYERTOKEN')));
      expect(written, isNot(contains('ABCDEFGHIJ')));
      expect(written, isNot(contains('QUERYTOKEN')));
      // A `d=` that does not read as an origin says so rather than guessing.
      expect(
        DiagnosticsLog.url(Uri.parse('http://127.0.0.1:11470/proxy/x=1/f')),
        'http://127.0.0.1:11470/proxy/d=…/…',
      );
    });

    test('redacts every URL in a line it did not compose', () {
      // mpv names the whole URL, full stop included, when it cannot open
      // it; media_kit and the platform do the same in exception text. The
      // line is redacted on the way into the ring, because the ring is what
      // logcat and the copied report both read.
      final lines = captureDiagnostics();
      DiagnosticsLog.warn(
        'mpv',
        'stream: Failed to open http://127.0.0.1:1/proxy/'
            'd=https%3A%2F%2Fdl.real-debrid.com&p=player-3/d/rdSECRETsigned1234/'
            'Movie.mkv?token=QUERYTOKENabc.',
      );
      DiagnosticsLog.error(
        'player',
        'open rejected: PlatformException(open, '
            'https://torrentio.strem.fun/realdebrid/RDAPIKEY0123/abc/null/0/Movie.mkv, '
            'not reachable)',
      );
      DiagnosticsLog.info('player', 'stalled; see https://example.org/help.');
      expect(lines, [
        'warn mpv stream: Failed to open '
            'http://127.0.0.1:1/proxy/d=dl.real-debrid.com/….',
        'error player open rejected: PlatformException(open, '
            'https://torrentio.strem.fun/…, not reachable)',
        'info player stalled; see https://example.org/….',
      ]);
      for (final line in lines) {
        expect(line, isNot(contains('SECRET')));
        expect(line, isNot(contains('TOKEN')));
        expect(line, isNot(contains('APIKEY')));
      }
      // The server's own URL is still worth having whole, and a line with
      // no URL in it is left exactly as it was.
      const opened =
          'open http://127.0.0.1:11470/abc123/0 at 0s (initial (torrent))';
      expect(DiagnosticsLog.redactUrls(opened), opened);
      expect(
        DiagnosticsLog.redactUrls('http:// is not a URL'),
        'http:// is not a URL',
      );
    });

    test('captures an unhandled Flutter error', () {
      final lines = captureDiagnostics();
      captureUnhandledErrors();
      final previous = FlutterError.onError;
      addTearDown(() => FlutterError.onError = previous);
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: StateError('a listener blew up'),
          library: 'xtremio test',
          context: ErrorDescription('while doing something'),
        ),
      );
      expect(
        lines.single,
        'error flutter Bad state: a listener blew up (while doing something)',
      );
    });
  });

  group('formatDiagnostics', () {
    test('skips the scrub while Verbose logging is on', () {
      addTearDown(() => DiagnosticsLog.unredacted = false);
      const snapshot = DiagnosticsSnapshot(
        coreVersion: '0.1.0',
        logLines: ['GET /catalog?apiKey=DEADBEEF0011&skip=100'],
      );
      String report() => formatDiagnostics(
        snapshot: snapshot,
        platform: 'android',
        osVersion: 'Android 14',
        at: DateTime.utc(2026, 9, 19),
      );

      expect(
        report(),
        isNot(contains('DEADBEEF0011')),
        reason: 'off: scrubbed',
      );
      DiagnosticsLog.unredacted = true;
      expect(
        report(),
        contains('DEADBEEF0011'),
        reason: 'on: as it was logged',
      );
    });

    test('a line written whole under Verbose logging leaves scrubbed once '
        'it is off', () {
      // On, play a Comet stream, off, copy the report into a public issue:
      // the lines from the verbose stretch are still in the 400-line ring.
      addTearDown(() => DiagnosticsLog.unredacted = false);
      final lines = captureDiagnostics();
      DiagnosticsLog.unredacted = true;
      DiagnosticsLog.info(
        'player',
        'open http://127.0.0.1:46503/proxy/d=https%3A%2F%2Fcomet.example'
            '&p=PLAYERTOKEN/COMETCONFIG/playback/abc at 0s',
      );
      DiagnosticsLog.unredacted = false;
      final report = formatDiagnostics(
        snapshot: DiagnosticsSnapshot(
          coreVersion: '0.1.0',
          logLines: [for (final line in lines) line],
        ),
        platform: 'android',
        osVersion: 'Android 14',
        at: DateTime.utc(2026, 9, 19),
      );
      expect(lines.single, contains('COMETCONFIG'), reason: 'written whole');
      expect(report, isNot(contains('COMETCONFIG')));
      expect(report, isNot(contains('PLAYERTOKEN')));
      expect(report, contains('/proxy/d=comet.example/…'));
    });

    test('heads the report with the build, device and server', () {
      final text = formatDiagnostics(
        snapshot: const DiagnosticsSnapshot(
          coreVersion: '0.1.0',
          streamServerRev: '7c46427bc09075b98f5febe10f2a90143e44d826',
          stremioCoreRev: '00265b3bad7158535fccf1e119e10d6ad492183e',
          serverBaseUrl: 'http://127.0.0.1:11470/',
          logLines: ['one', 'two'],
        ),
        platform: 'android',
        osVersion: 'Android 14 (API 34) · Google Pixel 7',
        at: DateTime.utc(2026, 9, 3, 15, 4, 19),
        // The state the owner's phone was actually in: a cache well over
        // its limit on a volume with nothing left, which is what "the
        // downloads run fast and the buffer stays at 0%" looks like from
        // here. It belongs above the log, not in it.
        storage: ServerStorage(
          cacheDir: '/data/user/0/com.zond.xtremio/cache/server',
          cacheUsedBytes: 17000000000,
          cacheLimitBytes: 10737418240,
          cacheVolume: const StorageVolume(
            path: '/data/user/0/com.zond.xtremio/cache/server',
            freeBytes: 402653184,
            totalBytes: 57000000000,
          ),
        ),
        appVersion: '1.0.0+1',
        gitCommit: '577fe03',
      );
      expect(text.split('\n'), [
        'Xtremio diagnostics',
        'taken: 2026-09-03T15:04:19.000Z',
        'app: 1.0.0+1 (commit 577fe03)',
        'core: xtremio_core 0.1.0',
        'platform: android · Android 14 (API 34) · Google Pixel 7',
        'server: running · http://127.0.0.1:11470/',
        'cache: 17.0 GB of 10.7 GB limit · '
            '/data/user/0/com.zond.xtremio/cache/server',
        'disk: 403 MB free of 57.0 GB',
        'stream-server: 7c46427bc09075b98f5febe10f2a90143e44d826',
        'stremio-core: 00265b3bad7158535fccf1e119e10d6ad492183e',
        'log: 2 lines, oldest first',
        '',
        'one',
        'two',
      ]);
    });

    test('says what it does not know, and redacts what it does', () {
      final text = formatDiagnostics(
        snapshot: const DiagnosticsSnapshot(
          coreVersion: '0.1.0',
          logLines: ['request authorization=Bearer sekrit-token-value'],
        ),
        platform: 'linux',
        osVersion: 'Linux 6.17',
        at: DateTime.utc(2026),
      );
      expect(text, contains('app: unknown'));
      // A server that is not running costs those two lines their numbers
      // and nothing else.
      expect(text, contains('cache: unknown'));
      expect(text, contains('disk: unknown'));
      expect(text, isNot(contains('(commit')));
      expect(text, contains('server: not running'));
      expect(text, contains('stream-server: unknown'));
      expect(text, contains('stremio-core: unknown'));
      expect(text, isNot(contains('sekrit-token-value')));
      expect(text, contains('authorization=<redacted>'));
      // Nothing was asked about the DHT here, and the header says nothing
      // about it either -- absence, not an `unknown` line, since most
      // sessions never have anything DHT-related worth reporting.
      expect(text, isNot(contains('dht:')));
    });

    group('the DHT line', () {
      DiagnosticsSnapshot snapshot() =>
          const DiagnosticsSnapshot(coreVersion: '0.1.0', logLines: []);

      test('says so, with the node counts, only while never bootstrapped', () {
        final text = formatDiagnostics(
          snapshot: snapshot(),
          platform: 'android',
          osVersion: 'Android 14',
          at: DateTime.utc(2026),
          dht: const DhtStatus(
            enabled: true,
            nodes: 0,
            nodesV6: 0,
            everBootstrapped: false,
          ),
        );
        expect(
          text,
          contains(
            'dht: DHT unavailable — using trackers only · 0 nodes (0 v6)',
          ),
        );
      });

      test('says nothing once bootstrapped, disabled, or unread', () {
        for (final dht in [
          const DhtStatus(
            enabled: true,
            nodes: 40,
            nodesV6: 3,
            everBootstrapped: true,
          ),
          const DhtStatus(
            enabled: false,
            nodes: 0,
            nodesV6: 0,
            everBootstrapped: false,
          ),
          null,
        ]) {
          final text = formatDiagnostics(
            snapshot: snapshot(),
            platform: 'android',
            osVersion: 'Android 14',
            at: DateTime.utc(2026),
            dht: dht,
          );
          expect(text, isNot(contains('dht:')), reason: '$dht');
        }
      });
    });
  });

  group('DiagnosticsScreen', () {
    /// Records what the app puts on the clipboard.
    List<String> interceptClipboard(WidgetTester tester) {
      final copied = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(
            (call.arguments as Map<Object?, Object?>)['text'] as String,
          );
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      return copied;
    }

    testWidgets('copies the redacted report and says how many lines', (
      tester,
    ) async {
      final copied = interceptClipboard(tester);
      final client = FakeDiagnosticsClient(
        snapshot: const DiagnosticsSnapshot(
          coreVersion: '0.1.0',
          streamServerRev: '7c46427bc09075b98f5febe10f2a90143e44d826',
          stremioCoreRev: '00265b3bad7158535fccf1e119e10d6ad492183e',
          serverBaseUrl: 'http://127.0.0.1:11470/',
          logLines: [
            'INFO xtremio_core::server: embedded stream-server started',
            'ERROR stream_server: request headers=authorization=Bearer s3cret',
            'ERROR mpv: Failed to open http://127.0.0.1:11470/abc/0',
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DiagnosticsScreen(
            client: client,
            now: () => DateTime.utc(2026, 9, 3),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The log is on screen, token and all -- redacted.
      expect(find.textContaining('embedded stream-server started'), findsOne);
      expect(find.textContaining('Failed to open'), findsOne);
      expect(find.textContaining('s3cret'), findsNothing);

      await tester.tap(find.text('Copy diagnostics'));
      await tester.pumpAndSettle();

      expect(copied, hasLength(1));
      expect(copied.single, startsWith('Xtremio diagnostics'));
      expect(
        copied.single,
        contains('platform: android · Android 14 (API 34)'),
      );
      expect(
        copied.single,
        contains('server: running · http://127.0.0.1:11470/'),
      );
      expect(copied.single, isNot(contains('s3cret')));
      expect(copied.single, contains('authorization=<redacted>'));
      expect(find.text('Copied 3 log lines to the clipboard.'), findsOneWidget);
    });

    testWidgets('says so when the core cannot answer, and copies nothing', (
      tester,
    ) async {
      final copied = interceptClipboard(tester);
      final client = FakeDiagnosticsClient(error: StateError('core is down'));
      await tester.pumpWidget(
        MaterialApp(home: DiagnosticsScreen(client: client)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Diagnostics unavailable'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(copied, isEmpty);

      // Refresh asks again, and a core that came up answers.
      client.error = null;
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(find.textContaining('Diagnostics unavailable'), findsNothing);
      expect(client.reads, 2);
    });

    testWidgets(
      'shows the DHT notice, node counts behind a tap, only while it is '
      'the news',
      (tester) async {
        final client = FakeDiagnosticsClient(
          dht: const DhtStatus(
            enabled: true,
            nodes: 0,
            nodesV6: 0,
            everBootstrapped: false,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: DiagnosticsScreen(
              client: client,
              now: () => DateTime.utc(2026, 9, 3),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Information, not in the way: the wording shows, the counts do
        // not, until it is opened.
        expect(
          find.text('DHT unavailable — using trackers only'),
          findsOneWidget,
        );
        expect(find.text('0 nodes (0 v6)'), findsNothing);
        await tester.tap(find.text('DHT unavailable — using trackers only'));
        await tester.pumpAndSettle();
        expect(find.text('0 nodes (0 v6)'), findsOneWidget);

        // A bootstrapped DHT is not news: nothing about it shows anywhere,
        // on screen or in what gets copied.
        client.dht = const DhtStatus(
          enabled: true,
          nodes: 40,
          nodesV6: 3,
          everBootstrapped: true,
        );
        await tester.tap(find.byIcon(Icons.refresh));
        await tester.pumpAndSettle();
        expect(
          find.text('DHT unavailable — using trackers only'),
          findsNothing,
        );
        expect(find.textContaining('nodes ('), findsNothing);

        final copied = interceptClipboard(tester);
        await tester.tap(find.text('Copy diagnostics'));
        await tester.pumpAndSettle();
        expect(copied.single, isNot(contains('dht:')));
      },
    );
  });
}
