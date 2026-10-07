import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/settings/settings_screen.dart';
import 'package:xtremio/widgets/internet_status_tile.dart';

import '../support/fake_core_client.dart';
import '../support/fixtures.dart';

const String sweden = '\u{1F1F8}\u{1F1EA}';
const Key row = Key('internet-status');

String trace({String loc = 'SE'}) => 'ip=203.0.113.7\nloc=$loc\n';

/// An [InternetStatusCheck] whose checks answer what [answer] says, counting
/// them in [asked].
InternetStatusCheck checkOf(String Function() answer, List<int> asked) =>
    InternetStatusCheck(
      fetch: () async {
        asked.add(asked.length + 1);
        return answer();
      },
    );

void main() {
  Widget settings(InternetStatusCheck check) => InternetStatusScope(
    check: check,
    child: CoreScope(
      client: FakeCoreClient(state: {CoreField.ctx: loadCtxLoggedOutFixture()}),
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );

  /// Settings laid out tall enough that every row is built at once.
  Future<void> pumpSettings(
    WidgetTester tester,
    InternetStatusCheck check,
  ) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(settings(check));
    await tester.pumpAndSettle();
  }

  testWidgets('connected: the flag, the country and the address', (
    tester,
  ) async {
    final check = checkOf(trace, []);
    await check.recheck();
    await pumpSettings(tester, check);

    expect(
      find.descendant(of: find.byKey(row), matching: find.text(sweden)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(row),
        matching: find.text('Connected to the internet'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(row),
        matching: find.text('SE · 203.0.113.7'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('it is the last row of Streaming server', (tester) async {
    final check = checkOf(trace, []);
    await check.recheck();
    await pumpSettings(tester, check);

    final top = tester.getTopLeft(find.byKey(row)).dy;
    expect(
      top,
      greaterThan(tester.getTopLeft(find.text('Streaming server')).dy),
    );
    expect(top, greaterThan(tester.getTopLeft(find.text('Peer discovery')).dy));
    expect(top, lessThan(tester.getTopLeft(find.text('Core')).dy));
  });

  testWidgets('a failed check is "No internet connection", and no address', (
    tester,
  ) async {
    final check = checkOf(() => throw Exception('offline'), []);
    await check.recheck();
    await pumpSettings(tester, check);

    expect(
      find.descendant(
        of: find.byKey(row),
        matching: find.text('No internet connection'),
      ),
      findsOneWidget,
    );
    expect(find.text(InternetStatusTile.connected), findsNothing);
    expect(find.textContaining('203.0.113.7'), findsNothing);
  });

  testWidgets('while the status is unknown there is no row', (tester) async {
    final check = checkOf(trace, []);
    await pumpSettings(tester, check);

    expect(find.byKey(row), findsNothing);
    expect(find.text(InternetStatusTile.noConnection), findsNothing);
  });

  testWidgets('pressing it asks again, and a connection that came back is '
      'shown', (tester) async {
    var online = false;
    final asked = <int>[];
    final check = checkOf(
      () => online ? trace() : throw Exception('offline'),
      asked,
    );
    await check.recheck();
    await pumpSettings(tester, check);
    expect(find.text(InternetStatusTile.noConnection), findsOneWidget);

    online = true;
    await tester.tap(find.byKey(row));
    await tester.pumpAndSettle();

    expect(asked, hasLength(2));
    expect(find.text(InternetStatusTile.connected), findsOneWidget);
  });

  testWidgets('an address with no country is the address and a globe', (
    tester,
  ) async {
    final check = checkOf(() => trace(loc: 'T1'), []);
    await check.recheck();
    await pumpSettings(tester, check);

    expect(
      find.descendant(of: find.byKey(row), matching: find.text('203.0.113.7')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(row), matching: find.byIcon(Icons.public)),
      findsOneWidget,
    );
  });
}
