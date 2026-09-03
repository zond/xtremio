import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/diagnostics/diagnostics_report.dart';
import 'package:xtremio/features/diagnostics/diagnostics_screen.dart';

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
      expect(
        redactSecrets('addon https://tor.example.com/DEBRIDKEY/manifest.json'),
        'addon https://tor.example.com/<redacted>/manifest.json',
      );
      expect(
        redactSecrets('stremio://x.io/a/b/manifest.json opened'),
        'stremio://x.io/<redacted>/manifest.json opened',
      );
      // An unconfigured addon's manifest has no secret in it, and its host
      // is what names the addon in a report.
      expect(
        redactSecrets('https://v3-cinemeta.strem.io/manifest.json'),
        'https://v3-cinemeta.strem.io/manifest.json',
      );
      expect(
        redactSecrets('fetch https://user:pass@host/x'),
        'fetch https://<redacted>@host/x',
      );
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

  group('formatDiagnostics', () {
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
        osVersion: 'Android 14 (API 34)',
        at: DateTime.utc(2026, 9, 3, 15, 4, 19),
        appVersion: '1.0.0+1',
        gitCommit: '577fe03',
      );
      expect(text.split('\n'), [
        'Xtremio diagnostics',
        'taken: 2026-09-03T15:04:19.000Z',
        'app: 1.0.0+1 (commit 577fe03)',
        'core: xtremio_core 0.1.0',
        'platform: android · Android 14 (API 34)',
        'server: running · http://127.0.0.1:11470/',
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
      expect(text, isNot(contains('(commit')));
      expect(text, contains('server: not running'));
      expect(text, contains('stream-server: unknown'));
      expect(text, contains('stremio-core: unknown'));
      expect(text, isNot(contains('sekrit-token-value')));
      expect(text, contains('authorization=<redacted>'));
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
  });
}
