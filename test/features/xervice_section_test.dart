import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/settings/xervice_section.dart';

import '../support/fake_prefs_client.dart';
import '../support/fake_xervice.dart';

/// Settings → Account: forgetting what xtremio-xervice keeps, asked first,
/// and told afterwards whether the service heard it.
void main() {
  const key = 'stremio-session-key-abcdef0123456789';

  Map<String, dynamic> signedIn() => {
    'profile': {
      'auth': {
        'key': key,
        'user': {'_id': 'user-a', 'email': 'a@example.com'},
      },
    },
  };

  late FakeXervice service;
  late FakeFacesStore store;
  late AppPrefs prefs;
  late ValueNotifier<Map<String, dynamic>?> ctx;

  Future<void> mount(WidgetTester tester, {bool scope = true}) async {
    prefs = AppPrefs(client: FakePrefsClient());
    addTearDown(prefs.dispose);
    await prefs.load();
    store = FakeFacesStore();
    service = FakeXervice(accounts: {key: 'user-a'})
      ..routes = (request, user) =>
          store.routes(request, user) ?? const XerviceAnswer(404);
    ctx = ValueNotifier(signedIn());
    addTearDown(ctx.dispose);
    final section = MaterialApp(
      home: Scaffold(body: XerviceSection(ctx: ctx)),
    );
    final sync = FacesSync(
      prefs: prefs,
      identity: XerviceIdentity(
        http: service,
        authKey: () => stremioAuthKeyOf(ctx.value),
      ),
    );
    await tester.pumpWidget(
      scope ? XerviceScope(faces: sync, child: section) : section,
    );
    await prefs.setFaces(
      Faces.empty.marking('tt1', Face.like, DateTime.utc(2026)),
    );
    await sync.sync();
    await tester.pumpAndSettle();
  }

  testWidgets('asks first, then forgets on the account and the device', (
    tester,
  ) async {
    await mount(tester);
    expect(store.byUser['user-a']!.of('tt1'), Face.like);

    await tester.tap(find.text(XerviceSection.forgetLikesTitle));
    await tester.pumpAndSettle();
    expect(find.text(XerviceSection.forgetLikesQuestion), findsOneWidget);

    // Cancel forgets nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.requests.where((r) => r.method == 'DELETE'), isEmpty);

    await tester.tap(find.text(XerviceSection.forgetLikesTitle));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    expect(find.text(XerviceSection.forgotten), findsOneWidget);
    expect(prefs.faces.marks, isEmpty);
    expect(store.byUser['user-a']!.marks, isEmpty);
  });

  testWidgets('offline, it says nothing was forgotten', (tester) async {
    await mount(tester);
    service.offline = true;
    await tester.tap(find.text(XerviceSection.forgetLikesTitle));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    expect(find.text(XerviceSection.notReached), findsOneWidget);
    expect(prefs.faces.of('tt1'), Face.like);
  });

  testWidgets('signed out, or with no service, there is nothing to forget', (
    tester,
  ) async {
    await mount(tester);
    ctx.value = {
      'profile': {'auth': null},
    };
    await tester.pumpAndSettle();
    expect(find.text(XerviceSection.forgetLikesTitle), findsNothing);

    await mount(tester, scope: false);
    expect(find.text(XerviceSection.forgetLikesTitle), findsNothing);
  });
}
