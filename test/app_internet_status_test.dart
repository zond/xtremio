import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/widgets/internet_status_tile.dart';

import 'support/empty_board.dart';
import 'support/fake_core_client.dart';
import 'support/fake_sharing.dart';
import 'support/fixtures.dart';

/// The app proving its internet connection: once when it comes up, again
/// each time it comes back from being away, and the answer on the
/// Settings screen.
void main() {
  /// A check that always finds Sweden, counting the checks in [asked].
  InternetStatusCheck checkOf(List<int> asked) => InternetStatusCheck(
    fetch: () async {
      asked.add(asked.length + 1);
      return 'ip=203.0.113.7\nloc=SE\n';
    },
  );

  Future<void> pumpApp(WidgetTester tester, InternetStatusCheck check) async {
    await tester.pumpWidget(
      XtremioApp(
        core: FakeCoreClient(
          state: {
            CoreField.ctx: loadCtxLoggedOutFixture(),
            CoreField.board: emptyBoard(),
          },
        ),
        sharingActivity: FakeSharingActivity(),
        internetStatus: check,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('it asks once when the app comes up', (tester) async {
    final asked = <int>[];
    final check = checkOf(asked);
    addTearDown(check.dispose);
    await pumpApp(tester, check);

    expect(asked, hasLength(1));
    expect(
      check.status,
      const InternetOnline(ip: '203.0.113.7', country: 'SE'),
    );
  });

  testWidgets('it asks again when the app comes back from being away', (
    tester,
  ) async {
    final asked = <int>[];
    final check = checkOf(asked);
    addTearDown(check.dispose);
    await pumpApp(tester, check);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(asked, hasLength(2));
  });

  testWidgets('a resume without having been away asks nothing more', (
    tester,
  ) async {
    final asked = <int>[];
    final check = checkOf(asked);
    addTearDown(check.dispose);
    await pumpApp(tester, check);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(asked, hasLength(1));
  });

  testWidgets('the answer is on the Settings screen', (tester) async {
    final check = checkOf([]);
    addTearDown(check.dispose);
    await pumpApp(tester, check);

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(InternetStatusTile.connected),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('SE · 203.0.113.7'), findsOneWidget);
  });

  testWidgets('a check handed in is the caller\'s: the app does not '
      'dispose it', (tester) async {
    final check = checkOf([]);
    await pumpApp(tester, check);

    await tester.pumpWidget(const SizedBox());

    // A disposed ChangeNotifier refuses a listener.
    expect(() => check.addListener(() {}), returnsNormally);
    check.dispose();
  });
}
