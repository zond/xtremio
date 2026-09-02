import 'package:flutter_test/flutter_test.dart';

import 'package:xtremio/app.dart';

void main() {
  testWidgets('app boots into the Board section with navigation', (
    tester,
  ) async {
    await tester.pumpWidget(const XtremioApp());

    // The default section renders.
    expect(find.text('Board'), findsWidgets);

    // All primary destinations are reachable from the shell.
    expect(find.text('Discover'), findsWidgets);
    expect(find.text('Library'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });
}
