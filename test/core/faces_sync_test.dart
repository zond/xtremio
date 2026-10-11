import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/diagnostics_capture.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_xervice.dart';

const String _key = 'stremio-session-key-abcdef0123456789';

void main() {
  late DateTime clock;
  late String? signedIn;
  late FakeXervice service;
  late FakeFacesStore store;
  late AppPrefs prefs;
  late FacesSync sync;

  setUp(() async {
    clock = DateTime.utc(2026, 10, 11, 12);
    signedIn = _key;
    store = FakeFacesStore(now: () => clock);
    service = FakeXervice(accounts: {_key: 'user-a'}, now: () => clock)
      ..routes = (request, user) =>
          store.routes(request, user) ?? const XerviceAnswer(404);
    prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();
    sync = FacesSync(
      prefs: prefs,
      identity: XerviceIdentity(
        http: service,
        authKey: () => signedIn,
        now: () => clock,
      ),
      now: () => clock,
    );
  });

  int ms(DateTime at) => at.millisecondsSinceEpoch;

  test('a press marks the device and sends the set to the account', () async {
    await sync.setFace('tt1', Face.like);
    expect(prefs.faces.of('tt1'), Face.like);
    expect(store.byUser['user-a']!.marks, {
      'tt1': FaceMark(Face.like, ms(clock)),
    });
    final put = service.requests.last;
    expect('${put.method} ${put.path}', 'PUT /faces');
  });

  test(
    'a first sync adds the device set to the account, dropping neither',
    () async {
      store.byUser['user-a'] = Faces({
        'tt-phone': const FaceMark(Face.dislike, 100),
        'tt-both': const FaceMark(Face.like, 500),
      });
      await prefs.setFaces(
        Faces({
          'tt-tv': const FaceMark(Face.like, 200),
          'tt-both': const FaceMark(Face.dislike, 300),
        }),
      );
      await sync.sync();
      final expected = {
        'tt-phone': const FaceMark(Face.dislike, 100),
        'tt-tv': const FaceMark(Face.like, 200),
        'tt-both': const FaceMark(Face.like, 500),
      };
      expect(prefs.faces.marks, expected);
      expect(store.byUser['user-a']!.marks, expected);
    },
  );

  test('signed out, a press stays on the device and nothing is sent', () async {
    signedIn = null;
    await sync.setFace('tt1', Face.dislike);
    expect(prefs.faces.of('tt1'), Face.dislike);
    expect(service.requests, isEmpty);
    // And the next sync, signed in, takes it to the account.
    signedIn = _key;
    await sync.sync();
    expect(store.byUser['user-a']!.of('tt1'), Face.dislike);
  });

  test('offline is a quiet sync that did not happen', () async {
    final lines = captureDiagnostics();
    service.offline = true;
    await sync.setFace('tt1', Face.like);
    expect(prefs.faces.of('tt1'), Face.like);
    expect(lines, ['info xervice identity: not reachable (SocketException)']);
  });

  test('forgetting empties the account and the device, and a device that '
      'has not heard cannot bring it back', () async {
    await sync.setFace('tt1', Face.like);
    clock = clock.add(const Duration(minutes: 1));
    expect(await sync.forgetEverywhere(), isTrue);
    expect(prefs.faces.marks, isEmpty);
    expect(store.byUser['user-a']!.marks, isEmpty);

    // Another device still holding the old like syncs it.
    final other = Faces({'tt1': FaceMark(Face.like, ms(clock) - 60000)});
    final answer = await service.send(
      'PUT',
      '/faces',
      body: other.toJson(),
      bearer: service.requests.last.bearer,
    );
    expect(Faces.fromJson(answer.json).marks, isEmpty);
  });

  test('forgetting offline says so and forgets nothing', () async {
    await sync.setFace('tt1', Face.like);
    service.offline = true;
    expect(await sync.forgetEverywhere(), isFalse);
    expect(prefs.faces.of('tt1'), Face.like);
  });

  test('a press while a sync is out is sent by one more after it', () async {
    final release = Completer<void>();
    service.holdRoutes = release.future;
    final held = sync.setFace('tt1', Face.like);
    await pumpEventQueue();
    final second = sync.setFace('tt2', Face.dislike);
    await pumpEventQueue();
    service.holdRoutes = null;
    release.complete();
    await Future.wait([held, second]);
    expect(
      service.requests.where((request) => request.path == '/faces'),
      hasLength(2),
    );
    expect(store.byUser['user-a']!.of('tt2'), Face.dislike);
    expect(prefs.faces.of('tt1'), Face.like);
  });
}
