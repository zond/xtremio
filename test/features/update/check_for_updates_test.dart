import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/settings/settings_screen.dart';
import 'package:xtremio/features/update/app_updates.dart';
import 'package:xtremio/features/update/check_for_updates_tile.dart';
import 'package:xtremio/features/update/update_dialog.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/focus_theme.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_updates.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// Settings under [updates], on a phone or on a television.
Widget settings(AppUpdates updates, {bool onTv = false}) {
  final core = FakeCoreClient(
    state: {CoreField.ctx: loadCtxLoggedOutFixture()},
  );
  final app = MaterialApp(
    theme: XtremioApp.themeFor(isTv: onTv),
    builder: onTv ? TvMediaQuery.builder : null,
    home: const SettingsScreen(),
  );
  return DeviceScope(
    profile: onTv ? tv : DeviceProfile.fallback,
    child: CoreScope(
      client: core,
      child: AppUpdatesScope(
        updates: updates,
        child: onTv ? AlwaysShowFocus(child: app) : app,
      ),
    ),
  );
}

Future<void> tapCheck(WidgetTester tester) async {
  final tile = find.text(CheckForUpdatesTile.title);
  await tester.scrollUntilVisible(
    tile,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('says up to date, which is an answer too', (tester) async {
    final source = FakeReleaseSource(release: sampleRelease(tag: 'v0.1.13'));
    await tester.pumpWidget(settings(fakeUpdates(source: source)));
    await tester.pumpAndSettle();
    await tapCheck(tester);
    expect(source.asked, 1);
    expect(find.text('xtremio 0.1.13 is up to date.'), findsOneWidget);
    expect(find.text('This is xtremio 0.1.13'), findsOneWidget);
  });

  testWidgets('asks again on every press, whatever the day\'s look said', (
    tester,
  ) async {
    final source = FakeReleaseSource(release: sampleRelease(tag: 'v0.1.13'));
    final prefs = AppPrefs.inMemory();
    await prefs.setUpdateCheckedAt(DateTime.utc(2026, 10, 3, 11));
    await tester.pumpWidget(
      settings(fakeUpdates(source: source, prefs: prefs)),
    );
    await tester.pumpAndSettle();
    await tapCheck(tester);
    await tester.tap(find.text(CheckForUpdatesTile.title));
    await tester.pumpAndSettle();
    expect(source.asked, 2);
  });

  testWidgets('a newer release opens the update dialog', (tester) async {
    await tester.pumpWidget(settings(fakeUpdates()));
    await tester.pumpAndSettle();
    await tapCheck(tester);
    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(find.text('xtremio 0.1.14 is available'), findsOneWidget);
  });

  testWidgets('a failure says what failed', (tester) async {
    final source = FakeReleaseSource(
      error: const FormatException('the latest release tag is not a version'),
    );
    await tester.pumpWidget(settings(fakeUpdates(source: source)));
    await tester.pumpAndSettle();
    await tapCheck(tester);
    expect(
      find.text(
        'Could not check for updates: the latest release tag is not a '
        'version.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a remote reaches it and presses it', (tester) async {
    useScreen(tester, tvSize);
    final source = FakeReleaseSource(release: sampleRelease(tag: 'v0.1.13'));
    await tester.pumpWidget(settings(fakeUpdates(source: source), onTv: true));
    await tester.pumpAndSettle();
    for (
      var i = 0;
      i < 60 && focusedLabel(tester) != CheckForUpdatesTile.title;
      i++
    ) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusedLabel(tester), CheckForUpdatesTile.title);
    expect(focusMarks(), isNotEmpty);
    await press(tester, LogicalKeyboardKey.select);
    expect(source.asked, 1);
    expect(find.text('xtremio 0.1.13 is up to date.'), findsOneWidget);
  });

  testWidgets('and from it, the dialog has the remote', (tester) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(settings(fakeUpdates(), onTv: true));
    await tester.pumpAndSettle();
    for (
      var i = 0;
      i < 60 && focusedLabel(tester) != CheckForUpdatesTile.title;
      i++
    ) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(focusedLabel(tester), UpdateDialog.updateLabel);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedLabel(tester), UpdateDialog.laterLabel);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(UpdateDialog), findsNothing);
    expect(focusedLabel(tester), CheckForUpdatesTile.title);
  });
}
