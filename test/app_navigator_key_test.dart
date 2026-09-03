import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';

import 'support/fake_core_client.dart';
import 'support/fixtures.dart';

/// A core with a `ctx` and a board that plans no catalogs, so the shell
/// settles instead of spinning.
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

/// Pushes with nothing but the key — no [BuildContext] anywhere, which is
/// the situation a link arriving from the platform is in.
void pushFromOutsideTheTree(GlobalKey<NavigatorState> key) {
  key.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('pushed from outside')),
    ),
  );
}

void main() {
  testWidgets('the app carries a navigator key that pushes a route from '
      'outside the tree', (tester) async {
    await tester.pumpWidget(
      XtremioApp(core: coreWith(loadCtxLoggedOutFixture())),
    );
    await tester.pumpAndSettle();

    final key = tester
        .widget<MaterialApp>(find.byType(MaterialApp))
        .navigatorKey;
    expect(key, isNotNull, reason: 'nothing outside the tree could navigate');

    pushFromOutsideTheTree(key!);
    await tester.pumpAndSettle();

    expect(find.text('pushed from outside'), findsOneWidget);
  });
}
