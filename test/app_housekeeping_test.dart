import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';

import 'support/fake_core_client.dart';
import 'support/fixtures.dart';

/// A core with the given `ctx` and a board that plans no catalogs (so the
/// Board section settles instead of spinning).
FakeCoreClient coreWith(Map<String, dynamic> ctx) => FakeCoreClient(
  state: {
    CoreField.ctx: ctx,
    CoreField.board: {
      'selected': {'type': null, 'extra': <Object>[]},
      'catalogs': <Object>[],
      'catalogLabels': <Object>[],
    },
  },
);

List<Map<String, dynamic>> ctxActions(FakeCoreClient core) => [
  for (final action in core.dispatched)
    if (action.field == CoreField.ctx) action.toJson(),
];

/// What a signed-in profile gets pulled, in stremio-web's order.
final accountPull = [
  CoreActions.pullAddonsFromAPI().toJson(),
  CoreActions.pullUserFromAPI().toJson(),
  CoreActions.syncLibraryWithAPI().toJson(),
  CoreActions.pullNotifications().toJson(),
];

Future<void> resume(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  await tester.pump();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an anonymous profile only pulls the addons at startup', (
    tester,
  ) async {
    final core = coreWith(loadCtxLoggedOutFixture());
    await tester.pumpWidget(XtremioApp(core: core));
    await tester.pumpAndSettle();

    expect(ctxActions(core), [CoreActions.pullAddonsFromAPI().toJson()]);
    expect(ctxActions(core).single['field'], 'ctx');
  });

  testWidgets('a signed-in profile pulls addons, user, library and '
      'notifications at startup', (tester) async {
    final core = coreWith(loadCtxLoggedInFixture());
    await tester.pumpWidget(XtremioApp(core: core));
    await tester.pumpAndSettle();

    expect(ctxActions(core), accountPull);
    // PullUserFromAPI needs its (empty) args object.
    expect(ctxActions(core)[1]['action'], {
      'action': 'Ctx',
      'args': {'action': 'PullUserFromAPI', 'args': <String, dynamic>{}},
    });
  });

  testWidgets('UserAuthenticated pulls the account', (tester) async {
    final core = coreWith(loadCtxLoggedOutFixture());
    await tester.pumpWidget(XtremioApp(core: core));
    await tester.pumpAndSettle();
    expect(ctxActions(core), hasLength(1));

    core.setState(CoreField.ctx, loadCtxLoggedInFixture());
    core.emit(
      const RuntimeCoreEvent({
        'event': 'UserAuthenticated',
        'args': {'auth_request': {}},
      }),
    );
    await tester.pumpAndSettle();

    expect(ctxActions(core).skip(1), accountPull);
  });

  group('on resume', () {
    testWidgets('a signed-in profile is pulled again', (tester) async {
      final core = coreWith(loadCtxLoggedInFixture());
      await tester.pumpWidget(XtremioApp(core: core));
      await tester.pumpAndSettle();
      expect(ctxActions(core), accountPull);

      await resume(tester);
      expect(ctxActions(core), [...accountPull, ...accountPull]);
    });

    testWidgets('an anonymous profile is left alone', (tester) async {
      final core = coreWith(loadCtxLoggedOutFixture());
      await tester.pumpWidget(XtremioApp(core: core));
      await tester.pumpAndSettle();

      await resume(tester);
      expect(ctxActions(core), [CoreActions.pullAddonsFromAPI().toJson()]);
    });

    testWidgets('the first resumed after launch does not repeat the '
        'startup pull', (tester) async {
      final core = coreWith(loadCtxLoggedInFixture());
      await tester.pumpWidget(XtremioApp(core: core));
      await tester.pumpAndSettle();

      // Straight to resumed, never having been away.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(ctxActions(core), accountPull);

      // A later background/foreground cycle counts.
      await resume(tester);
      expect(ctxActions(core), [...accountPull, ...accountPull]);
    });

    testWidgets('who signed in meanwhile is pulled', (tester) async {
      final core = coreWith(loadCtxLoggedOutFixture());
      await tester.pumpWidget(XtremioApp(core: core));
      await tester.pumpAndSettle();

      core.setState(CoreField.ctx, loadCtxLoggedInFixture());
      await tester.pumpAndSettle();
      await resume(tester);
      expect(ctxActions(core), [
        CoreActions.pullAddonsFromAPI().toJson(),
        ...accountPull,
      ]);
    });
  });
}
