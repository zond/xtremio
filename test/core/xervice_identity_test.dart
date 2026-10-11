import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/diagnostics/diagnostics_report.dart';

import '../support/diagnostics_capture.dart';
import '../support/fake_xervice.dart';

const String _key = 'stremio-session-key-abcdef0123456789';
const String _other = 'another-session-key-9876543210fedcba';

void main() {
  late DateTime clock;
  late String? signedIn;
  late FakeXervice service;
  late XerviceIdentity identity;

  setUp(() {
    clock = DateTime.utc(2026, 10, 11, 12);
    signedIn = _key;
    service = FakeXervice(
      accounts: {_key: 'user-a', _other: 'user-b'},
      now: () => clock,
    )..routes = (request, user) => XerviceAnswer(200, {'user': user});
    identity = XerviceIdentity(
      http: service,
      authKey: () => signedIn,
      now: () => clock,
    );
  });

  test('reads the session key out of ctx, and nothing when signed out', () {
    expect(
      stremioAuthKeyOf({
        'profile': {
          'auth': {
            'key': _key,
            'user': {'_id': 'user-a'},
          },
        },
      }),
      _key,
    );
    expect(
      stremioAuthKeyOf({
        'profile': {'auth': null},
      }),
      isNull,
    );
    expect(stremioAuthKeyOf({'profile': {}}), isNull);
    expect(stremioAuthKeyOf(null), isNull);
  });

  test('asks for a token once and sends it until it is near expiry', () async {
    expect((await identity.send('GET', '/faces'))!.json, {'user': 'user-a'});
    expect((await identity.send('GET', '/faces'))!.json, {'user': 'user-a'});
    expect(service.identityCalls, 1);
    expect(service.requests.first.body, {'authKey': _key});

    // Inside the renewal margin: a fresh one is asked for first.
    clock = clock.add(
      service.tokenLife - XerviceIdentity.renewAhead + Duration.zero,
    );
    await identity.send('GET', '/faces');
    expect(service.identityCalls, 2);
  });

  test('a refused token is renewed once and the request sent again', () async {
    await identity.send('GET', '/faces');
    service.expireTokens();
    final answer = await identity.send('GET', '/faces');
    expect(answer!.status, 200);
    expect(service.identityCalls, 2);
    expect(service.requests.map((request) => request.path), [
      '/identity',
      '/faces',
      '/faces',
      '/identity',
      '/faces',
    ]);
  });

  test('two requests at once share one renewal', () async {
    await Future.wait([
      identity.send('GET', '/faces'),
      identity.send('GET', '/vault/drive'),
    ]);
    expect(service.identityCalls, 1);
  });

  test('signed out sends nothing at all, and drops the held token', () async {
    await identity.send('GET', '/faces');
    signedIn = null;
    expect(await identity.send('GET', '/faces'), isNull);
    expect(service.requests, hasLength(2));
    expect(identity.signedIn, isFalse);
  });

  test('a sign-out while the token is out keeps nothing of it', () async {
    final release = Completer<void>();
    service.holdIdentity = release.future;
    final asked = identity.token();
    await pumpEventQueue();
    signedIn = null;
    release.complete();
    expect(await asked, isNull);
    service.holdIdentity = null;
    signedIn = _key;
    await identity.send('GET', '/faces');
    expect(service.identityCalls, 2);
  });

  test('another account is another token, never the last one', () async {
    await identity.send('GET', '/faces');
    signedIn = _other;
    final answer = await identity.send('GET', '/faces');
    expect(answer!.json, {'user': 'user-b'});
    expect(service.identityCalls, 2);
    expect(service.requests.last.bearer, isNot(service.requests[1].bearer));
  });

  test('offline or a key Stremio refuses is a quiet null', () async {
    final lines = captureDiagnostics();
    service.offline = true;
    expect(await identity.send('GET', '/faces'), isNull);
    service.offline = false;
    signedIn = 'a-key-stremio-does-not-know-000000';
    expect(await identity.send('GET', '/faces'), isNull);
    expect(lines, [
      'info xervice identity: not reachable (SocketException)',
      'info xervice identity: refused (401)',
    ]);
  });

  test('the session key and the token reach no log line', () async {
    final lines = captureDiagnostics();
    await identity.send('GET', '/faces');
    service.expireTokens();
    await identity.send('PUT', '/faces', body: {'faces': {}});
    service.offline = true;
    identity.forget();
    await identity.send('GET', '/faces');
    expect(lines, isNotEmpty);
    final issued = [for (final request in service.requests) ?request.bearer];
    expect(issued, isNotEmpty);
    for (final line in lines) {
      expect(line, isNot(contains(_key)));
      for (final token in issued) {
        expect(line, isNot(contains(token)));
      }
    }
  });

  test('a report that quoted either would have them scrubbed', () {
    final text = redactSecrets(
      'POST /identity {"authKey":"$_key"} -> {"token":"v1.eyJzdWIi.c2ln",'
      '"expiresAt":"2026-10-11T13:00:00.000Z"}\n'
      'GET /faces Authorization: Bearer v1.eyJzdWIi.c2ln\n'
      'PUT /vault/drive {"refreshToken":"1//0g-refresh"}',
    );
    expect(text, isNot(contains(_key)));
    expect(text, isNot(contains('v1.eyJzdWIi.c2ln')));
    expect(text, isNot(contains('1//0g-refresh')));
    expect(text, contains('"expiresAt":"2026-10-11T13:00:00.000Z"'));
  });
}
