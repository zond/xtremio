import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/diagnostics_capture.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_xervice.dart';

const String _key = 'stremio-session-key-abcdef0123456789';
const String _keyB = 'stremio-session-key-of-account-b-000';

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
    service =
        FakeXervice(
            accounts: {_key: 'user-a', _keyB: 'user-b'},
            now: () => clock,
          )
          ..routes = (request, user) =>
              store.routes(request, user) ?? const XerviceAnswer(404);
    prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();
    prefs.setFacesOwner('user-a');
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

  group('marks are kept per account', () {
    /// Signs [user] in with [key], as the app does from `ctx`.
    void signIn(String? user, String? key) {
      signedIn = key;
      prefs.setFacesOwner(user);
    }

    test(
      "A's marks never reach B, stay on the device, and come back with A",
      () async {
        await sync.setFace('tt-a', Face.like);
        expect(store.byUser['user-a']!.of('tt-a'), Face.like);

        signIn(null, null);
        expect(prefs.faces.of('tt-a'), isNull, reason: 'hidden signed out');
        signIn('user-b', _keyB);
        expect(prefs.faces.of('tt-a'), isNull, reason: 'hidden from B');
        await sync.setFace('tt-b', Face.dislike);
        await sync.sync();
        expect(store.byUser['user-b']!.marks.keys, ['tt-b']);
        expect(prefs.facesByAccount.of('user-a').of('tt-a'), Face.like);

        signIn('user-a', _key);
        expect(prefs.faces.of('tt-a'), Face.like);
        expect(prefs.faces.of('tt-b'), isNull);
      },
    );

    test(
      "nobody's marks reach the first account that signs in, once",
      () async {
        signIn(null, null);
        await sync.setFace('tt-anon', Face.like);
        expect(prefs.faces.of('tt-anon'), Face.like);
        expect(service.requests, isEmpty);

        signIn('user-a', _key);
        expect(prefs.faces.of('tt-anon'), Face.like, reason: 'shown at once');
        await sync.sync();
        expect(store.byUser['user-a']!.of('tt-anon'), Face.like);
        expect(prefs.facesByAccount.of(null).marks, isEmpty, reason: 'once');
        expect(prefs.facesByAccount.of('user-a').of('tt-anon'), Face.like);

        signIn('user-b', _keyB);
        await sync.sync();
        expect(store.byUser['user-b']?.of('tt-anon'), isNull);
      },
    );

    test('a sign-in to another account while a sync is out keeps the '
        'answer away from it', () async {
      await sync.setFace('tt-a', Face.like);
      final release = Completer<void>();
      service.holdRoutes = release.future;
      final out = sync.setFace('tt-a2', Face.like);
      await pumpEventQueue();
      signIn('user-b', _keyB);
      service.holdRoutes = null;
      release.complete();
      await out;
      expect(prefs.facesByAccount.of('user-b').marks, isEmpty);
      expect(prefs.faces.of('tt-a'), isNull);
      expect(prefs.facesByAccount.of('user-a').of('tt-a2'), Face.like);
    });

    test('forgetting also drops the marks made signed out, which would be '
        "this account's at the next sync", () async {
      signIn(null, null);
      // A device clock ahead of the service's: the mark is newer than the
      // forgetting, so only dropping it makes it go.
      final real = clock;
      clock = clock.add(const Duration(hours: 1));
      await sync.setFace('tt-anon', Face.like);
      clock = real;
      signIn('user-a', _key);
      expect(await sync.forgetEverywhere(), isTrue);
      expect(prefs.faces.marks, isEmpty);
      await sync.sync();
      expect(store.byUser['user-a']!.marks, isEmpty);
    });
  });

  test('a stored set from before owners is the signed-out one', () async {
    final client = FakePrefsClient({
      AppPrefs.facesKey: Faces({'tt1': const FaceMark(Face.like, 5)}).toJson(),
    });
    final old = AppPrefs(client: client);
    await old.load();
    expect(old.facesByAccount.of(null).of('tt1'), Face.like);
    expect(old.faces.of('tt1'), Face.like);
  });
}
