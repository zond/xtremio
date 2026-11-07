import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/navigation_bar_clearance.dart';

/// Android draws the app behind its navigation bar. A screen pushed over the
/// tabs ended under the three-button bar, its last row behind the buttons.
void main() {
  const screen = Size(400, 800);
  const bar = 48.0;

  /// A pushed screen with no tab bar, its last row at the very bottom.
  Widget app() => const MaterialApp(
    builder: NavigationBarClearance.builder,
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(key: ValueKey('last row'), height: 40, width: 400),
      ),
    ),
  );

  void withNavigationBar(WidgetTester tester) {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: bar);
    tester.view.viewPadding = const FakeViewPadding(bottom: bar);
    addTearDown(tester.view.reset);
  }

  testWidgets('on Android, the last row ends above the navigation bar', (
    tester,
  ) async {
    withNavigationBar(tester);
    await tester.pumpWidget(app());

    final row = tester.getRect(find.byKey(const ValueKey('last row')));
    expect(row.bottom, screen.height - bar);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a hidden bar takes no room', (tester) async {
    // The player hides the bars, and then the picture reaches the edge.
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());

    final row = tester.getRect(find.byKey(const ValueKey('last row')));
    expect(row.bottom, screen.height);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('elsewhere, nothing changes', (tester) async {
    withNavigationBar(tester);
    await tester.pumpWidget(app());

    final row = tester.getRect(find.byKey(const ValueKey('last row')));
    expect(row.bottom, screen.height);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
