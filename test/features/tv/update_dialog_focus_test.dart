import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/update/apk_installer.dart';
import 'package:xtremio/features/update/app_updates.dart';
import 'package:xtremio/features/update/update_dialog.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/focus_theme.dart';
import 'package:xtremio/shell/tv_density.dart';
import 'package:xtremio/widgets/readout.dart';

import '../../support/fake_updates.dart';
import '../../support/tv.dart';

/// The update dialog with a remote and nothing else: every press here is
/// an arrow or select, never a tap.
///
/// The dialog is what a television sees once a day at most, on top of
/// whatever screen it came up over, and the system's own confirmation
/// after it is Android's (and beyond a widget test). What is here is that
/// the remote lands on the dialog's buttons, walks them, reads the notes
/// and reaches every step's buttons in turn.
void main() {
  final navigator = GlobalKey<NavigatorState>();

  /// Long enough to be taller than the dialog's room on a 720p screen.
  final longNotes = [
    '## What changed',
    for (var i = 1; i <= 40; i++) '- Change number $i',
  ].join('\n');

  Future<void> open(WidgetTester tester, AppUpdates updates) async {
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      DeviceScope(
        profile: tv,
        child: AlwaysShowFocus(
          child: MaterialApp(
            navigatorKey: navigator,
            theme: XtremioApp.themeFor(isTv: true),
            builder: TvMediaQuery.builder,
            home: const Scaffold(body: SizedBox()),
          ),
        ),
      ),
    );
    unawaited(
      showUpdateDialog(
        navigator.currentContext!,
        updates: updates,
        release: sampleRelease(notes: longNotes),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('focus starts on Update, marked, and walks the buttons', (
    tester,
  ) async {
    await open(tester, fakeUpdates());
    expect(focusedLabel(tester), UpdateDialog.updateLabel);
    expect(focusMarks(), isNotEmpty);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedLabel(tester), UpdateDialog.skipLabel);
    expect(focusMarks(), isNotEmpty);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedLabel(tester), UpdateDialog.laterLabel);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedLabel(tester), UpdateDialog.updateLabel);
  });

  testWidgets('up reads the notes, a screenful at a time, and down comes '
      'back to the buttons', (tester) async {
    await open(tester, fakeUpdates());
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<Readout>(), isTrue);
    expect(focusMarks(), isNotEmpty);
    expect(find.textContaining('• Change number 40'), findsOneWidget);
    // The last line is below the fold until the remote walks to it.
    final scrollable = find.descendant(
      of: find.byType(UpdateDialog),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, 0);
    for (var i = 0; i < 20 && focusIn<Readout>(); i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
      if (focusIn<Readout>()) expect(position.pixels, greaterThan(0));
    }
    expect(position.pixels, position.maxScrollExtent);
    expect(focusIn<Readout>(), isFalse);
    expect(
      focusedLabel(tester),
      isIn([
        UpdateDialog.laterLabel,
        UpdateDialog.skipLabel,
        UpdateDialog.updateLabel,
      ]),
    );
  });

  testWidgets('select on Update downloads and installs', (tester) async {
    final installer = FakeApkInstaller(abi: 'armeabi-v7a');
    await open(tester, fakeUpdates(installer: installer));
    await press(tester, LogicalKeyboardKey.select);
    expect(installer.installed, hasLength(1));
    expect(find.byType(UpdateDialog), findsNothing);
  });

  testWidgets('every step after the offer puts the remote on its buttons', (
    tester,
  ) async {
    final installer = FakeApkInstaller(allowed: false);
    final gate = Completer<void>();
    await open(
      tester,
      fakeUpdates(
        installer: installer,
        downloader: () => FakeApkDownloader(gate: gate),
      ),
    );
    await press(tester, LogicalKeyboardKey.select);
    // Downloading: Cancel is the one way out, and it has the remote.
    expect(focusedLabel(tester), UpdateDialog.cancelLabel);
    gate.complete();
    await tester.pumpAndSettle();

    // No permission yet: the setting first, then Install.
    expect(focusedLabel(tester), UpdateDialog.openSettingsLabel);
    await press(tester, LogicalKeyboardKey.select);
    expect(installer.settingsOpened, 1);
    expect(focusedLabel(tester), UpdateDialog.installLabel);
    expect(focusMarks(), isNotEmpty);

    installer.outcome = const InstallOutcome(InstallResult.aborted);
    await press(tester, LogicalKeyboardKey.select);
    expect(installer.installed, hasLength(1));
    // Turned down on Android's screen: Try again has the remote.
    expect(find.text('The update was not installed.'), findsOneWidget);
    expect(focusedLabel(tester), UpdateDialog.retryLabel);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedLabel(tester), UpdateDialog.closeLabel);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(UpdateDialog), findsNothing);
  });

  testWidgets('Skip this version is two presses away', (tester) async {
    final prefs = AppPrefs.inMemory();
    await open(tester, fakeUpdates(prefs: prefs));
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.select);
    expect(prefs.updateSkippedTag, 'v0.1.14');
    expect(find.byType(UpdateDialog), findsNothing);
  });
}
