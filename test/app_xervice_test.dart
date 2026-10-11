import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';

import 'support/empty_board.dart';
import 'support/fake_core_client.dart';
import 'support/fake_prefs_client.dart';
import 'support/fake_sharing.dart';
import 'support/fake_xervice.dart';
import 'support/fixtures.dart';

/// The app keeps its copies on xtremio-xervice in step with the account:
/// at a signed-in start and at every sign-in, and never signed out.
void main() {
  late FakeXervice service;
  late FakeFacesStore store;

  FakeCoreClient coreWith(Map<String, dynamic> ctx) => FakeCoreClient(
    state: {CoreField.ctx: ctx, CoreField.board: emptyBoard()},
  );

  String keyOf(Map<String, dynamic> ctx) => stremioAuthKeyOf(ctx)!;

  setUp(() {
    store = FakeFacesStore();
    service = FakeXervice(accounts: {keyOf(loadCtxLoggedInFixture()): 'user-a'})
      ..routes = (request, user) =>
          store.routes(request, user) ?? const XerviceAnswer(404);
  });

  Future<AppPrefs> prefsWithALike() async {
    final prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();
    await prefs.setFaces(
      Faces.empty.marking('tt1', Face.like, DateTime.utc(2026)),
    );
    return prefs;
  }

  testWidgets('a signed-in start syncs the faces', (tester) async {
    final prefs = await prefsWithALike();
    await tester.pumpWidget(
      XtremioApp(
        core: coreWith(loadCtxLoggedInFixture()),
        prefs: prefs,
        sharingActivity: FakeSharingActivity(),
        xervice: service,
      ),
    );
    await tester.pumpAndSettle();
    expect(store.byUser['user-a']!.of('tt1'), Face.like);
  });

  testWidgets('signed out asks nothing; a sign-in syncs', (tester) async {
    final prefs = await prefsWithALike();
    final core = coreWith(loadCtxLoggedOutFixture());
    await tester.pumpWidget(
      XtremioApp(
        core: core,
        prefs: prefs,
        sharingActivity: FakeSharingActivity(),
        xervice: service,
      ),
    );
    await tester.pumpAndSettle();
    expect(service.requests, isEmpty);

    core.setState(CoreField.ctx, loadCtxLoggedInFixture());
    await tester.pumpAndSettle();
    expect(store.byUser['user-a']!.of('tt1'), Face.like);
  });
}
