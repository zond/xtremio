import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/update/apk_installer.dart';
import 'package:xtremio/features/diagnostics/server_storage_screen.dart';
import 'package:xtremio/features/update/app_updates.dart';
import 'package:xtremio/features/update/install_room.dart';
import 'package:xtremio/features/update/update_dialog.dart';
import 'package:xtremio/shell/external_link.dart';

import '../../support/fake_link_opener.dart';
import '../../support/fake_server_cache.dart';
import '../../support/fake_updates.dart';

final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

/// A phone with [updates] behind it and the dialog for [sampleRelease] up.
Future<void> openDialog(
  WidgetTester tester,
  AppUpdates updates, {
  FakeLinkOpener? links,
}) async {
  await tester.pumpWidget(
    ExternalLinkScope(
      opener: links ?? FakeLinkOpener(),
      child: MaterialApp(
        navigatorKey: _navigator,
        home: const Scaffold(body: SizedBox()),
      ),
    ),
  );
  unawaited(
    showUpdateDialog(
      _navigator.currentContext!,
      updates: updates,
      release: sampleRelease(),
    ),
  );
  await tester.pumpAndSettle();
}

/// A 4 GB volume with [free] bytes free: its reserve is 200 MB, so the
/// 1 kB sample APK needs 200,003,000 bytes before the download and
/// 200,002,000 before the install.
DataVolumeRoom fourGb(int free) =>
    DataVolumeRoom(freeBytes: free, totalBytes: 4000000000);

/// A server whose clean never answers.
class _StuckCache extends FakeServerCache {
  @override
  Future<EvictionReport> cleanCacheNow() {
    cleans++;
    return Completer<EvictionReport>().future;
  }
}

/// The button labelled [label], whichever kind of Material button it is.
Finder button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
);

void main() {
  testWidgets('offers the release with its notes as text', (tester) async {
    await openDialog(tester, fakeUpdates());
    expect(find.text('xtremio 0.1.14 is available'), findsOneWidget);
    expect(find.text('This is xtremio 0.1.13.'), findsOneWidget);
    expect(
      find.text('What changed\n\n• Faster start\n• Fewer stalls'),
      findsOneWidget,
    );
    expect(button(UpdateDialog.updateLabel), findsOneWidget);
    expect(button(UpdateDialog.skipLabel), findsOneWidget);
    expect(button(UpdateDialog.laterLabel), findsOneWidget);
  });

  testWidgets('Update downloads the APK for this device and installs it', (
    tester,
  ) async {
    final installer = FakeApkInstaller(abi: 'armeabi-v7a');
    final downloads = <FakeApkDownloader>[];
    final updates = fakeUpdates(
      installer: installer,
      downloader: () {
        final downloader = FakeApkDownloader();
        downloads.add(downloader);
        return downloader;
      },
    );
    await openDialog(tester, updates);
    await tester.tap(button(UpdateDialog.updateLabel));
    await tester.pumpAndSettle();

    // The 32-bit APK, which is what a Chromecast with Google TV runs.
    expect(
      downloads.single.asked.single.path,
      endsWith('/xtremio-armeabi-v7a.apk'),
    );
    expect(installer.installed, [
      '/nonexistent/updates/xtremio-v0.1.14-armeabi-v7a.apk',
    ]);
    // Success: the dialog is gone (and on a device, so is the process).
    expect(find.byType(UpdateDialog), findsNothing);
  });

  testWidgets('Update has the server clean its cache before the download '
      'and again before the install', (tester) async {
    final cache = FakeServerCache(cleanResult: cleanedNothing);
    int? cleansAtInstall;
    final installer = FakeApkInstaller(
      onInstall: () => cleansAtInstall = cache.cleans,
    );
    var cleansAtDownload = -1;
    await openDialog(
      tester,
      fakeUpdates(
        installer: installer,
        cache: cache,
        downloader: () {
          cleansAtDownload = cache.cleans;
          return FakeApkDownloader();
        },
      ),
    );
    // Offering it reclaims nothing: only the press does.
    expect(cache.cleans, 0);
    await tester.tap(button(UpdateDialog.updateLabel));
    await tester.pumpAndSettle();
    expect(cleansAtDownload, 1);
    expect(cleansAtInstall, 2);
    expect(installer.installed, hasLength(1));
  });

  testWidgets('Later reclaims nothing', (tester) async {
    final cache = FakeServerCache(cleanResult: cleanedNothing);
    await openDialog(tester, fakeUpdates(cache: cache));
    await tester.tap(button(UpdateDialog.laterLabel));
    await tester.pumpAndSettle();
    expect(cache.cleans, 0);
  });

  testWidgets('without the room it downloads nothing, says how much is '
      'free and needed, and offers Server storage', (tester) async {
    final installer = FakeApkInstaller(volume: fourGb(150000000));
    var downloads = 0;
    await openDialog(
      tester,
      fakeUpdates(
        installer: installer,
        downloader: () {
          downloads++;
          return FakeApkDownloader();
        },
      ),
    );
    await tester.tap(button(UpdateDialog.updateLabel));
    await tester.pumpAndSettle();
    expect(find.text('Not enough space for the update'), findsOneWidget);
    expect(
      find.text(
        'The update needs 200 MB free on this device and there is 150 MB, '
        'after emptying the torrent cache of everything it could give back. '
        'What is left there is a download you kept or the title you played '
        'last; Server storage shows it.',
      ),
      findsOneWidget,
    );
    expect(downloads, 0);
    expect(installer.installed, isEmpty);

    await tester.tap(button(UpdateDialog.storageLabel));
    await tester.pumpAndSettle();
    expect(find.byType(ServerStorageScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Room made elsewhere: Try again goes on from where it stopped.
    installer.volume = fourGb(1000000000);
    await tester.tap(button(UpdateDialog.retryLabel));
    await tester.pumpAndSettle();
    expect(downloads, 1);
    expect(installer.installed, hasLength(1));
  });

  testWidgets('the room is measured again before the install', (tester) async {
    final installer = FakeApkInstaller(allowed: false);
    await openDialog(tester, fakeUpdates(installer: installer));
    await tester.tap(button(UpdateDialog.updateLabel));
    await tester.pumpAndSettle();
    expect(find.text('Allow xtremio to install apps'), findsOneWidget);

    // The disk filled while the permission was being found.
    installer.volume = fourGb(200001999);
    await tester.tap(button(UpdateDialog.installLabel));
    await tester.pumpAndSettle();
    expect(find.text('Not enough space for the update'), findsOneWidget);
    expect(installer.installed, isEmpty);

    installer.volume = fourGb(200002000);
    await tester.tap(button(UpdateDialog.retryLabel));
    await tester.pumpAndSettle();
    expect(installer.installed, hasLength(1));
  });

  testWidgets('a volume nobody could measure is not a full one', (
    tester,
  ) async {
    final installer = FakeApkInstaller(volume: null);
    await openDialog(tester, fakeUpdates(installer: installer));
    await tester.tap(button(UpdateDialog.updateLabel));
    await tester.pumpAndSettle();
    expect(installer.installed, hasLength(1));
  });

  testWidgets('a clean that does not answer is waited for only so long', (
    tester,
  ) async {
    final cache = _StuckCache();
    final installer = FakeApkInstaller();
    await openDialog(tester, fakeUpdates(installer: installer, cache: cache));
    await tester.tap(button(UpdateDialog.updateLabel));
    await tester.pump();
    expect(find.text('Making room for xtremio 0.1.14'), findsOneWidget);
    expect(find.text(UpdateDialog.roomText), findsOneWidget);
    await tester.pump(AppUpdates.cleanBound - const Duration(seconds: 1));
    expect(installer.installed, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    // The download's clean, then the install's: each waited out in turn.
    await tester.pump(AppUpdates.cleanBound);
    await tester.pumpAndSettle();
    expect(cache.cleans, 2);
    expect(installer.installed, hasLength(1));
  });

  testWidgets('shows how far the download is, and Cancel stops it', (
    tester,
  ) async {
    final gate = Completer<void>();
    final downloader = FakeApkDownloader(gate: gate);
    final installer = FakeApkInstaller();
    await openDialog(
      tester,
      fakeUpdates(installer: installer, downloader: () => downloader),
    );
    await tester.tap(button(UpdateDialog.updateLabel));
    await tester.pump();
    expect(find.text('Downloading xtremio 0.1.14'), findsOneWidget);
    expect(find.text('400 B of 1.0 kB'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.4,
    );

    await tester.tap(button(UpdateDialog.cancelLabel));
    await tester.pumpAndSettle();
    expect(downloader.cancelled, isTrue);
    expect(find.byType(UpdateDialog), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(installer.installed, isEmpty);
  });

  testWidgets('a failed download says why and tries again', (tester) async {
    var attempt = 0;
    final installer = FakeApkInstaller();
    await openDialog(
      tester,
      fakeUpdates(
        installer: installer,
        downloader: () => FakeApkDownloader(
          failure: attempt++ == 0 ? 'The download stopped.' : null,
        ),
      ),
    );
    await tester.tap(button(UpdateDialog.updateLabel));
    await tester.pumpAndSettle();
    expect(find.text('The update did not install'), findsOneWidget);
    expect(find.text('The download stopped.'), findsOneWidget);
    expect(installer.installed, isEmpty);

    await tester.tap(button(UpdateDialog.retryLabel));
    await tester.pumpAndSettle();
    expect(installer.installed, hasLength(1));
  });

  testWidgets('a signature mismatch says to uninstall the old app first', (
    tester,
  ) async {
    final installer = FakeApkInstaller(
      outcome: const InstallOutcome(
        InstallResult.conflict,
        'INSTALL_FAILED_UPDATE_INCOMPATIBLE',
      ),
    );
    var downloads = 0;
    await openDialog(
      tester,
      fakeUpdates(
        installer: installer,
        downloader: () {
          downloads++;
          return FakeApkDownloader();
        },
      ),
    );
    await tester.tap(button(UpdateDialog.updateLabel));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Android refused the update as conflicting with the installed '
        'xtremio (INSTALL_FAILED_UPDATE_INCOMPATIBLE). That is what an '
        'install from before v0.1.8 gets: it is signed with a different '
        'key. Uninstall xtremio first, then install the new version; '
        'uninstalling removes its login, settings and downloads.',
      ),
      findsOneWidget,
    );
    // Try again installs the file already verified, without a download.
    await tester.tap(button(UpdateDialog.retryLabel));
    await tester.pumpAndSettle();
    expect(installer.installed, hasLength(2));
    expect(downloads, 1);
  });

  testWidgets('without the install permission it explains, opens the '
      'setting, and installs on Install', (tester) async {
    final installer = FakeApkInstaller(allowed: false);
    await openDialog(tester, fakeUpdates(installer: installer));
    await tester.tap(button(UpdateDialog.updateLabel));
    await tester.pumpAndSettle();
    expect(find.text('Allow xtremio to install apps'), findsOneWidget);
    expect(installer.installed, isEmpty);

    await tester.tap(button(UpdateDialog.openSettingsLabel));
    await tester.pumpAndSettle();
    expect(installer.settingsOpened, 1);
    expect(
      find.text(
        'Turn on "Allow from this source" for xtremio, come back, and press '
        'Install.',
      ),
      findsOneWidget,
    );
    await tester.tap(button(UpdateDialog.installLabel));
    await tester.pumpAndSettle();
    expect(installer.installed, hasLength(1));
  });

  testWidgets('where the setting has no shortcut, it says where it is', (
    tester,
  ) async {
    final installer = FakeApkInstaller(allowed: false, settingsOpen: false);
    await openDialog(tester, fakeUpdates(installer: installer));
    await tester.tap(button(UpdateDialog.updateLabel));
    await tester.pumpAndSettle();
    await tester.tap(button(UpdateDialog.openSettingsLabel));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Settings > Apps > Special app access'),
      findsOneWidget,
    );
    expect(find.textContaining('Unknown sources'), findsOneWidget);
  });

  testWidgets('Skip this version remembers the tag; Later remembers nothing', (
    tester,
  ) async {
    final prefs = AppPrefs.inMemory();
    await openDialog(tester, fakeUpdates(prefs: prefs));
    await tester.tap(button(UpdateDialog.laterLabel));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
    expect(prefs.updateSkippedTag, isNull);

    await openDialog(tester, fakeUpdates(prefs: prefs));
    await tester.tap(button(UpdateDialog.skipLabel));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
    expect(prefs.updateSkippedTag, 'v0.1.14');
  });

  testWidgets('a desktop opens the release page instead', (tester) async {
    final links = FakeLinkOpener();
    final installer = FakeApkInstaller();
    await openDialog(
      tester,
      fakeUpdates(installsHere: false, installer: installer),
      links: links,
    );
    expect(button(UpdateDialog.updateLabel), findsNothing);
    await tester.tap(button(UpdateDialog.openPageLabel));
    await tester.pumpAndSettle();
    expect(links.opened, [
      Uri.parse('https://github.com/zond/xtremio/releases/tag/v0.1.14'),
    ]);
    expect(installer.installed, isEmpty);
  });

  testWidgets('a debug build is only pointed at the page, and told why', (
    tester,
  ) async {
    final links = FakeLinkOpener();
    final installer = FakeApkInstaller();
    await openDialog(
      tester,
      fakeUpdates(identity: debugBuild, installer: installer),
      links: links,
    );
    expect(
      find.text(
        'This is a debug build, a separate app from the release, so it '
        'cannot install the update. Install the release from its page.',
      ),
      findsOneWidget,
    );
    expect(button(UpdateDialog.updateLabel), findsNothing);
    await tester.tap(button(UpdateDialog.openPageLabel));
    await tester.pumpAndSettle();
    expect(links.opened, hasLength(1));
    expect(installer.installed, isEmpty);
  });

  testWidgets('a device the release has no APK for gets the page', (
    tester,
  ) async {
    await openDialog(
      tester,
      fakeUpdates(installer: FakeApkInstaller(abi: 'x86_64')),
    );
    expect(
      find.text(
        'This release has no build for this device (x86_64). Its page lists '
        'every file.',
      ),
      findsOneWidget,
    );
    expect(button(UpdateDialog.openPageLabel), findsOneWidget);
    expect(button(UpdateDialog.updateLabel), findsNothing);
  });
}
