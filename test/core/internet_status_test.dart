import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/internet_status.dart';

/// Cloudflare's `cdn-cgi/trace` answer, trimmed to a few of its lines.
String trace({String ip = '203.0.113.7', String? loc = 'SE'}) => [
  'fl=123f45',
  'h=www.cloudflare.com',
  'ip=$ip',
  'ts=1791400000.123',
  'visit_scheme=https',
  if (loc != null) 'loc=$loc',
  'tls=TLSv1.3',
].join('\n');

void main() {
  group('parseCloudflareTrace', () {
    test('reads the address and the country', () {
      expect(
        parseCloudflareTrace(trace()),
        const InternetOnline(ip: '203.0.113.7', country: 'SE'),
      );
    });

    test('an IPv6 address is read as written', () {
      expect(parseCloudflareTrace(trace(ip: '2001:db8::1'))?.ip, '2001:db8::1');
    });

    test('XX and Tor\'s T1 are no country; the address still is', () {
      for (final loc in ['XX', 'T1']) {
        final online = parseCloudflareTrace(trace(loc: loc));
        expect(online?.ip, '203.0.113.7');
        expect(online?.country, isNull, reason: loc);
        expect(online?.flag, isNull, reason: loc);
      }
    });

    test('no loc line is no country', () {
      expect(parseCloudflareTrace(trace(loc: null))?.country, isNull);
    });

    test('no address is nothing read', () {
      expect(parseCloudflareTrace('loc=SE\nfl=1'), isNull);
      expect(parseCloudflareTrace('<html>not a trace</html>'), isNull);
    });
  });

  test('a flag is the two regional indicator symbols', () {
    expect(flagOf('SE'), '\u{1F1F8}\u{1F1EA}');
    expect(flagOf('us'), '\u{1F1FA}\u{1F1F8}');
    expect(const InternetOnline(ip: 'x', country: 'NL').flag, '🇳🇱');
  });

  group('InternetStatusCheck', () {
    test('it is unknown until a check has answered or failed', () {
      expect(
        InternetStatusCheck(fetch: () async => trace()).status,
        const InternetUnknown(),
      );
    });

    test('a check that answers is online, and says so', () async {
      final check = InternetStatusCheck(fetch: () async => trace());
      var notified = 0;
      check.addListener(() => notified++);

      await check.recheck();

      expect(
        check.status,
        const InternetOnline(ip: '203.0.113.7', country: 'SE'),
      );
      expect(notified, 1);
    });

    test('a check that fails is offline, and says so', () async {
      final check = InternetStatusCheck(
        fetch: () async => throw Exception('offline'),
      );
      var notified = 0;
      check.addListener(() => notified++);

      await check.recheck();

      expect(check.status, const InternetOffline());
      expect(notified, 1, reason: 'a failure is news when nothing was known');
    });

    test('an answer with no address in it is offline', () async {
      final check = InternetStatusCheck(fetch: () async => '<html></html>');
      await check.recheck();
      expect(check.status, const InternetOffline());
    });

    test('a failure after being online is offline', () async {
      // The internet is not reachable now, whatever it was before.
      var fail = false;
      final check = InternetStatusCheck(
        fetch: () async => fail ? throw Exception('offline') : trace(),
      );
      await check.recheck();
      expect(check.status, isA<InternetOnline>());

      fail = true;
      await check.recheck();
      expect(check.status, const InternetOffline());
    });

    test(
      'only the newest check lands, whatever order they answer in',
      () async {
        final answers = <Completer<String>>[];
        final check = InternetStatusCheck(
          fetch: () {
            final answer = Completer<String>();
            answers.add(answer);
            return answer.future;
          },
        );
        final first = check.recheck();
        final second = check.recheck();

        answers[1].complete(trace(loc: 'NL'));
        await second;
        answers[0].complete(trace(loc: 'SE'));
        await first;

        expect(
          check.status,
          const InternetOnline(ip: '203.0.113.7', country: 'NL'),
        );
      },
    );

    test('the same answer again notifies nobody', () async {
      final check = InternetStatusCheck(fetch: () async => trace());
      await check.recheck();
      var notified = 0;
      check.addListener(() => notified++);

      await check.recheck();

      expect(notified, 0);
    });

    test('a check that answers after dispose changes nothing and throws '
        'nothing', () async {
      final answer = Completer<String>();
      final check = InternetStatusCheck(fetch: () => answer.future);
      final pending = check.recheck();
      check.dispose();

      answer.complete(trace());
      await pending;

      expect(check.status, const InternetUnknown());
    });
  });

  group('fetchCloudflareTrace', () {
    /// A server on this machine answering every request with [status] and
    /// [body], and the user agent each request carried.
    Future<(Uri, List<String?>)> serving(int status, String body) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final agents = <String?>[];
      server.listen((request) async {
        agents.add(request.headers.value(HttpHeaders.userAgentHeader));
        request.response
          ..statusCode = status
          ..write(body);
        await request.response.close();
      });
      return (Uri.parse('http://127.0.0.1:${server.port}/'), agents);
    }

    test('asks Cloudflare\'s trace unless told otherwise', () {
      expect(
        cloudflareTraceEndpoint.toString(),
        'https://www.cloudflare.com/cdn-cgi/trace',
      );
      expect(InternetStatusCheck().fetch, fetchCloudflareTrace);
    });

    test('answers the body of a 200, asking as xtremio', () async {
      final (uri, agents) = await serving(200, trace());
      expect(await fetchCloudflareTrace(endpoint: uri), trace());
      expect(agents, ['xtremio']);
    });

    test('anything but 200 is an error, not a body', () async {
      final (uri, _) = await serving(503, 'ip=203.0.113.7\nloc=SE\n');
      await expectLater(
        fetchCloudflareTrace(endpoint: uri),
        throwsA(isA<HttpException>()),
      );
    });

    test('a server that never answers is a timeout, not a hang', () async {
      // Accepts the connection and then says nothing at all, so the only
      // way out is the bound.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      server.listen(held.add);
      addTearDown(() async {
        for (final socket in held) {
          socket.destroy();
        }
        await server.close();
      });
      await expectLater(
        fetchCloudflareTrace(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}/'),
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('and a check over it is online', () async {
      final (uri, _) = await serving(200, trace(loc: 'NL'));
      final check = InternetStatusCheck(
        fetch: () => fetchCloudflareTrace(endpoint: uri),
      );
      await check.recheck();
      expect(
        check.status,
        const InternetOnline(ip: '203.0.113.7', country: 'NL'),
      );
    });
  });
}
