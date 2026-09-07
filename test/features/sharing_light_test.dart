import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/settings/core_settings.dart';
import 'package:xtremio/features/sharing/idle_sharing.dart';
import 'package:xtremio/features/sharing/sharing_activity.dart';
import 'package:xtremio/features/sharing/sharing_light.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';

import '../support/fake_core_client.dart';
import '../support/fake_downloads_client.dart';
import '../support/fake_sharing.dart';
import '../support/fixtures.dart';
import '../support/tv.dart';

/// The status light in the shell's corner: when it is drawn, which glyph,
/// what pressing it offers, and that each answer does exactly what it says.
void main() {
  const phone = DeviceProfile.fallback;
  const lightKey = Key('sharing-light');

  /// The server serving other people, with nothing playing.
  void seeding(FakeSharingActivity server) => server.answer = traffic(up: true);

  /// Nothing moving either way.
  void quiet(FakeSharingActivity server) => server.answer = traffic();

  FakeCoreClient fakeCore() => FakeCoreClient(
    state: {
      CoreField.board: loadBoardFixture(),
      CoreField.continueWatchingPreview: loadContinueWatchingFixture(),
      CoreField.library: loadLibraryFixture(),
      CoreField.ctx: loadCtxLoggedOutFixture(),
    },
  );

  /// The shell as the app mounts it, over one monitor, one policy and one
  /// downloads client.
  Widget harness({
    required SharingActivityMonitor monitor,
    required IdleSharingPolicy policy,
    required AppPrefs prefs,
    DownloadsClient? downloads,
    DeviceProfile device = phone,
    GlobalKey<NavigatorState>? navigator,
  }) => DeviceScope(
    profile: device,
    child: CoreScope(
      client: fakeCore(),
      child: DownloadsScope(
        client: downloads ?? FakeDownloadsClient(),
        child: PrefsScope(
          prefs: prefs,
          child: SharingScope(
            policy: policy,
            monitor: monitor,
            child: MaterialApp(
              navigatorKey: navigator,
              home: const RootShell(),
            ),
          ),
        ),
      ),
    ),
  );

  /// A registry row as `downloads_list` answers it, in [state] with
  /// [downloaded] of [size] bytes on disk.
  DownloadView download(
    String metaId,
    String name, {
    DownloadState state = DownloadState.downloading,
    int downloaded = 120000000,
    int size = 1500000000,
  }) => DownloadView({
    'metaId': metaId,
    'videoId': metaId,
    'type': 'movie',
    'name': name,
    'state': state.wireName,
    'downloaded': downloaded,
    'size': size,
    'createdAt': '2026-09-0${metaId.length % 9 + 1}T10:00:00Z',
  });

  /// A downloads client holding [views].
  FakeDownloadsClient downloadsOf(List<DownloadView> views) =>
      FakeDownloadsClient(
        registry: DownloadsRegistry(
          items: {for (final view in views) view.key: view},
        ),
      );

  /// Everything one of these tests needs, wired the way the app wires it.
  ({
    FakeSharingActivity server,
    SharingActivityMonitor monitor,
    IdleSharingPolicy policy,
    AppPrefs prefs,
    RecordingServerSettings settings,
  })
  setUpSharing(WidgetTester tester) {
    // The pulse repeats for as long as the light is drawn, and
    // `pumpAndSettle` waits for a frame that never comes; a platform that
    // says animations are off is also the path the light itself takes.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final server = FakeSharingActivity();
    final monitor = SharingActivityMonitor(
      client: server,
      period: const Duration(milliseconds: 20),
    );
    addTearDown(monitor.dispose);
    final prefs = AppPrefs.inMemory();
    final settings = RecordingServerSettings();
    final policy = IdleSharingPolicy(prefs: prefs, server: settings);
    addTearDown(policy.dispose);
    policy.start();
    return (
      server: server,
      monitor: monitor,
      policy: policy,
      prefs: prefs,
      settings: settings,
    );
  }

  /// One poll and the frame that answers it.
  Future<void> poll(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 25));
    await tester.pumpAndSettle();
  }

  group('the light', () {
    testWidgets('stays out while the setting is on and nothing is going out', (
      tester,
    ) async {
      final s = setUpSharing(tester);
      // On, which is the default, and the whole point of the light: an icon
      // that answers the switch instead of the wire says nothing.
      expect(s.prefs.shareWhileIdle, isTrue);
      quiet(s.server);
      await tester.pumpWidget(
        harness(monitor: s.monitor, policy: s.policy, prefs: s.prefs),
      );
      await tester.pumpAndSettle();
      await poll(tester);

      expect(s.server.reads, greaterThan(0), reason: 'the server was asked');
      expect(find.byKey(lightKey), findsNothing);
    });

    testWidgets('comes on when the server says bytes are going out, with '
        'the up arrow', (tester) async {
      final s = setUpSharing(tester);
      quiet(s.server);
      await tester.pumpWidget(
        harness(monitor: s.monitor, policy: s.policy, prefs: s.prefs),
      );
      await tester.pumpAndSettle();
      await poll(tester);
      expect(find.byKey(lightKey), findsNothing);

      seeding(s.server);
      await poll(tester);

      expect(find.byKey(lightKey), findsOneWidget);
      expect(find.byIcon(SharingLight.uploadingIcon), findsOneWidget);
      expect(find.byIcon(SharingLight.downloadingIcon), findsNothing);
      expect(find.byIcon(SharingLight.bothIcon), findsNothing);
      expect(find.bySemanticsLabel('Uploading to other people'), findsWidgets);
    });

    testWidgets('shows the down arrow while bytes are coming in', (
      tester,
    ) async {
      // A download filling in while nothing plays lights it as much as a
      // share does: what the viewer is told about is the connection.
      final s = setUpSharing(tester);
      s.server.answer = traffic(down: true);
      await tester.pumpWidget(
        harness(monitor: s.monitor, policy: s.policy, prefs: s.prefs),
      );
      await tester.pumpAndSettle();
      await poll(tester);

      expect(find.byKey(lightKey), findsOneWidget);
      expect(find.byIcon(SharingLight.downloadingIcon), findsOneWidget);
      expect(find.byIcon(SharingLight.uploadingIcon), findsNothing);
      expect(find.byIcon(SharingLight.bothIcon), findsNothing);
      expect(find.bySemanticsLabel('Downloading'), findsWidgets);
    });

    testWidgets('shows one glyph with both arrows while both are true, '
        'never two lights', (tester) async {
      final s = setUpSharing(tester);
      s.server.answer = traffic(up: true, down: true);
      await tester.pumpWidget(
        harness(monitor: s.monitor, policy: s.policy, prefs: s.prefs),
      );
      await tester.pumpAndSettle();
      await poll(tester);

      expect(find.byKey(lightKey), findsOneWidget);
      expect(find.byIcon(SharingLight.bothIcon), findsOneWidget);
      expect(find.byIcon(SharingLight.uploadingIcon), findsNothing);
      expect(find.byIcon(SharingLight.downloadingIcon), findsNothing);
      // One slot: the light is one button however many directions are lit.
      expect(find.byType(SharingLight), findsOneWidget);
      expect(find.byKey(lightKey), findsOneWidget);
    });

    testWidgets('changes glyph as the traffic changes direction', (
      tester,
    ) async {
      final s = setUpSharing(tester);
      seeding(s.server);
      await tester.pumpWidget(
        harness(monitor: s.monitor, policy: s.policy, prefs: s.prefs),
      );
      await tester.pumpAndSettle();
      await poll(tester);
      expect(find.byIcon(SharingLight.uploadingIcon), findsOneWidget);

      s.server.answer = traffic(up: true, down: true);
      await poll(tester);
      expect(find.byIcon(SharingLight.bothIcon), findsOneWidget);

      s.server.answer = traffic(down: true);
      await poll(tester);
      expect(find.byIcon(SharingLight.downloadingIcon), findsOneWidget);
      expect(find.byIcon(SharingLight.bothIcon), findsNothing);
    });

    testWidgets('stays out while a film is playing, whatever is moving', (
      tester,
    ) async {
      // The server folds "nothing playing" into both halves itself: a
      // reading taken during a film has bytes moving and both halves dark,
      // and the light follows the halves. (The shell also stops asking
      // while a player is on top; this is the other lock.)
      final s = setUpSharing(tester);
      s.server.answer = const BackgroundTraffic(
        active: false,
        downloading: false,
        uploading: false,
        playing: true,
        bytesDownloaded: 9000000,
        bytesUploaded: 800000,
        windowSecs: 5,
      );
      await tester.pumpWidget(
        harness(monitor: s.monitor, policy: s.policy, prefs: s.prefs),
      );
      await tester.pumpAndSettle();
      await poll(tester);

      expect(s.server.reads, greaterThan(0));
      expect(find.byKey(lightKey), findsNothing);
    });

    testWidgets('goes out again when the sharing stops', (tester) async {
      final s = setUpSharing(tester);
      seeding(s.server);
      await tester.pumpWidget(
        harness(monitor: s.monitor, policy: s.policy, prefs: s.prefs),
      );
      await tester.pumpAndSettle();
      await poll(tester);
      expect(find.byKey(lightKey), findsOneWidget);

      // Nothing more goes out.
      quiet(s.server);
      await poll(tester);

      expect(find.byKey(lightKey), findsNothing);
    });

    testWidgets('is not drawn, and nothing is asked, while something is on '
        'top of the shell', (tester) async {
      final s = setUpSharing(tester);
      final navigator = GlobalKey<NavigatorState>();
      seeding(s.server);
      await tester.pumpWidget(
        harness(
          monitor: s.monitor,
          policy: s.policy,
          prefs: s.prefs,
          navigator: navigator,
        ),
      );
      await tester.pumpAndSettle();
      await poll(tester);
      expect(find.byKey(lightKey), findsOneWidget);

      // Standing in for the player: what the shell can honestly answer is
      // that its own route is no longer the one on screen.
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink()),
        ),
      );
      // The very next frame, before the monitor has been told to stop and
      // long before its answer could change: what the shell draws is
      // decided by what is on top of it, not by a reading that is about to
      // be dropped.
      await tester.pump();
      expect(find.byKey(lightKey), findsNothing);
      await tester.pumpAndSettle();
      final asked = s.server.reads;
      await poll(tester);
      await poll(tester);

      expect(find.byKey(lightKey), findsNothing);
      expect(s.monitor.watching, isFalse);
      expect(s.server.reads, asked, reason: 'the polling stopped with it');

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await poll(tester);
      expect(find.byKey(lightKey), findsOneWidget);
    });

    testWidgets('lets go of the server when the shell is torn down', (
      tester,
    ) async {
      final s = setUpSharing(tester);
      seeding(s.server);
      await tester.pumpWidget(
        harness(monitor: s.monitor, policy: s.policy, prefs: s.prefs),
      );
      await tester.pumpAndSettle();
      await poll(tester);
      expect(find.byKey(lightKey), findsOneWidget);

      // The app going away while the light is lit: the watch ends with it,
      // and the notification that ends it must not reach a tree that is
      // being taken apart.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final asked = s.server.reads;
      await poll(tester);

      expect(s.monitor.watching, isFalse);
      expect(s.server.reads, asked);
    });

    testWidgets('goes out when the server cannot be asked at all', (
      tester,
    ) async {
      final s = setUpSharing(tester);
      seeding(s.server);
      await tester.pumpWidget(
        harness(monitor: s.monitor, policy: s.policy, prefs: s.prefs),
      );
      await tester.pumpAndSettle();
      await poll(tester);
      expect(find.byKey(lightKey), findsOneWidget);

      // Not knowing is not the same as knowing nothing is going out, but a
      // light that stays on says something nobody can support.
      s.server.failure = StateError('server is not running');
      await poll(tester);

      expect(find.byKey(lightKey), findsNothing);
    });
  });

  group('off a television', () {
    testWidgets('the light is a button of its own, and the shell keeps its '
        'node', (tester) async {
      final s = setUpSharing(tester);
      seeding(s.server);
      await tester.pumpWidget(
        harness(monitor: s.monitor, policy: s.policy, prefs: s.prefs),
      );
      await tester.pumpAndSettle();
      await poll(tester);
      expect(find.byKey(lightKey), findsOneWidget);

      // The node the shell owns is a television's -- it exists so a rail
      // key can put focus on the light -- and nothing here takes it, so it
      // is not in the focus tree at all while the light is lit.
      expect(
        FocusManager.instance.rootScope.descendants.map((n) => n.debugLabel),
        isNot(contains('sharing light')),
      );

      // Tab still finds the light, through the button's own node: this is
      // an ordinary focusable, not the shell's node the D-pad is kept off.
      for (var i = 0; i < 40 && !focusIn<SharingLight>(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      expect(focusIn<SharingLight>(), isTrue);
      final node = FocusManager.instance.primaryFocus!;
      expect(node.debugLabel, isNot('sharing light'));
      expect(node.skipTraversal, isFalse);
    });
  });

  group('pressing it', () {
    /// The shell with the light lit and its popup open.
    Future<
      ({
        FakeSharingActivity server,
        SharingActivityMonitor monitor,
        IdleSharingPolicy policy,
        AppPrefs prefs,
        RecordingServerSettings settings,
      })
    >
    openPopup(
      WidgetTester tester, {
      bool sharing = true,
      BackgroundTraffic? reading,
      DownloadsClient? downloads,
    }) async {
      final s = setUpSharing(tester);
      if (!sharing) await s.prefs.setShareWhileIdle(false);
      s.server.answer = reading ?? traffic(up: true);
      await tester.pumpWidget(
        harness(
          monitor: s.monitor,
          policy: s.policy,
          prefs: s.prefs,
          downloads: downloads,
        ),
      );
      await tester.pumpAndSettle();
      await poll(tester);
      await tester.tap(find.byKey(lightKey));
      await tester.pumpAndSettle();
      return s;
    }

    /// Every row in the open popup that a press does something on.
    Finder pressableRows() => find.descendant(
      of: find.byType(SharingStopDialog),
      matching: find.byWidgetPredicate((w) => w is ListTile && w.onTap != null),
    );

    testWidgets('while uploading, offers both sharing stops and a way out '
        'of neither', (tester) async {
      await openPopup(tester);

      expect(find.text('Uploading to other people'), findsOneWidget);
      expect(find.byKey(SharingStopDialog.notNowKey), findsOneWidget);
      expect(find.byKey(SharingStopDialog.stopKey), findsOneWidget);
      expect(find.byKey(SharingStopDialog.closeKey), findsOneWidget);
      // What each one costs is on the row, not left to be guessed from a
      // pair of button labels.
      expect(find.text(IdleSharing.pauseDescription), findsOneWidget);
      expect(find.text(IdleSharing.stopDescription), findsOneWidget);
      // Nothing about downloads: no bytes are coming in, so a download row
      // would be a row about the wrong arrow.
      expect(find.byKey(SharingStopDialog.noDownloadKey), findsNothing);
      expect(find.text(SharingStopDialog.uploadingHeading), findsNothing);
      expect(find.text(SharingStopDialog.downloadingHeading), findsNothing);
      expect(pressableRows(), findsNWidgets(2));
    });

    testWidgets('offers no stop at all while the setting is already off', (
      tester,
    ) async {
      // A state the light is honestly in, since it is drawn from bytes
      // measured leaving the device and never from the setting: the switch
      // is off and something the switch does not govern is still uploading
      // -- a torrent serving out its idle grace, a title kept offline. Both
      // stops are about that setting, so both would be actions with nothing
      // to do: a "Not now" that pauses a setting already off, and a "Stop
      // sharing" that turns off a switch already off.
      final s = await openPopup(tester, sharing: false);

      expect(find.byKey(SharingStopDialog.notNowKey), findsNothing);
      expect(find.byKey(SharingStopDialog.stopKey), findsNothing);
      expect(find.text(IdleSharing.alreadyOffTitle), findsOneWidget);
      expect(find.text(IdleSharing.alreadyOffDescription), findsOneWidget);

      // The way out is still there, and there is no row a press would do
      // nothing on.
      expect(pressableRows(), findsNothing);
      await tester.tap(find.byKey(SharingStopDialog.closeKey));
      await tester.pumpAndSettle();
      await s.policy.settled;

      expect(find.byType(SharingStopDialog), findsNothing);
      expect(s.policy.pausedForRun, isFalse);
      expect(s.prefs.shareWhileIdle, isFalse);
      // Still going out -- that is the whole state -- so still lit.
      expect(find.byKey(lightKey), findsOneWidget);
    });

    testWidgets('"Not now" stops the server without writing the setting '
        'down', (tester) async {
      final s = await openPopup(tester);
      expect(s.settings.patches, [
        {IdleSharing.seedingEnabledKey: true},
      ]);

      await tester.tap(find.byKey(SharingStopDialog.notNowKey));
      await tester.pumpAndSettle();
      await s.policy.settled;

      expect(s.settings.patches.last, {IdleSharing.seedingEnabledKey: false});
      // The choice is untouched: this run is what ends, not the setting.
      expect(s.prefs.shareWhileIdle, isTrue);
      expect(s.policy.pausedForRun, isTrue);
      expect(find.byType(SharingStopDialog), findsNothing);
    });

    testWidgets('after a "Not now" it says so, and draws no row that would '
        'do nothing', (tester) async {
      // The reported shape: light lit, switch on, "Not now" taken. The
      // server is told to stop, but the light answers measured bytes and
      // not the server's belief -- the torrent serves out its idle grace, a
      // pinned title keeps going -- so it stays lit, and the light is
      // pressed again.
      final s = await openPopup(tester);
      await tester.tap(find.byKey(SharingStopDialog.notNowKey));
      await tester.pumpAndSettle();
      await s.policy.settled;
      expect(s.policy.pausedForRun, isTrue);
      await poll(tester);
      expect(find.byKey(lightKey), findsOneWidget);

      await tester.tap(find.byKey(lightKey));
      await tester.pumpAndSettle();

      // A second "Not now" is a row drawn and dead, since the policy takes
      // no second pause: it is not drawn. What is drawn instead says the
      // pause is in force, and the one stop left with something to do --
      // the switch -- is still offered.
      expect(find.byKey(SharingStopDialog.notNowKey), findsNothing);
      expect(find.byKey(SharingStopDialog.pausedKey), findsOneWidget);
      expect(find.text(IdleSharing.pausedTitle), findsOneWidget);
      expect(find.byKey(SharingStopDialog.stopKey), findsOneWidget);
      // Every row with a press on it changes something: the only pressable
      // row is the switch.
      final pressable = pressableRows();
      expect(pressable, findsOneWidget);
      expect(tester.widget<ListTile>(pressable).key, SharingStopDialog.stopKey);

      // The stop it does offer does what it says from here as well.
      await tester.tap(find.byKey(SharingStopDialog.stopKey));
      await tester.pumpAndSettle();
      await s.policy.settled;
      expect(find.byType(SharingStopDialog), findsNothing);
      expect(s.prefs.shareWhileIdle, isFalse);
      expect(s.policy.pausedForRun, isFalse);
    });

    testWidgets('"Stop sharing" writes the same preference the settings '
        'switch does', (tester) async {
      final s = await openPopup(tester);

      await tester.tap(find.byKey(SharingStopDialog.stopKey));
      await tester.pumpAndSettle();
      await s.policy.settled;

      expect(s.prefs.shareWhileIdle, isFalse);
      // And it reaches the server by the one path that writes it.
      expect(s.settings.patches.last, {IdleSharing.seedingEnabledKey: false});
      expect(s.policy.pausedForRun, isFalse);
      expect(find.byType(SharingStopDialog), findsNothing);
    });

    testWidgets('dismissing does neither', (tester) async {
      final s = await openPopup(tester);

      await tester.tap(find.byKey(SharingStopDialog.closeKey));
      await tester.pumpAndSettle();
      await s.policy.settled;

      expect(find.byType(SharingStopDialog), findsNothing);
      expect(s.prefs.shareWhileIdle, isTrue);
      expect(s.policy.pausedForRun, isFalse);
      expect(s.settings.patches, [
        {IdleSharing.seedingEnabledKey: true},
      ]);
      // Still going out, so still lit.
      expect(find.byKey(lightKey), findsOneWidget);
    });

    testWidgets('while downloading, offers a Cancel per download on its way '
        'and no sharing row', (tester) async {
      final downloads = downloadsOf([
        download('tt1', 'Alien'),
        download('tt2', 'Aliens', state: DownloadState.queued, downloaded: 0),
        download('tt3', 'Alien 3', state: DownloadState.complete),
      ]);
      final s = await openPopup(
        tester,
        reading: traffic(down: true),
        downloads: downloads,
      );

      expect(find.text('Downloading'), findsOneWidget);
      // One row per download still on its way; the finished one is not a
      // download in flight and gets none.
      expect(
        find.byKey(SharingStopDialog.cancelKey('tt1:tt1')),
        findsOneWidget,
      );
      expect(
        find.byKey(SharingStopDialog.cancelKey('tt2:tt2')),
        findsOneWidget,
      );
      expect(find.byKey(SharingStopDialog.cancelKey('tt3:tt3')), findsNothing);
      expect(find.text('Cancel Alien'), findsOneWidget);
      // What each costs is on the row: the part-file goes with it, and a
      // download nothing has arrived for says so instead of naming 0 B.
      expect(
        find.text(
          'Stops keeping it offline and deletes the 120 MB that has '
          'arrived so far.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Stops keeping it offline. Nothing has arrived yet.'),
        findsOneWidget,
      );
      // The sharing rows govern the other arrow and are not drawn here.
      expect(find.byKey(SharingStopDialog.notNowKey), findsNothing);
      expect(find.byKey(SharingStopDialog.stopKey), findsNothing);
      expect(find.byKey(SharingStopDialog.noDownloadKey), findsNothing);
      // And no heading: the one "Downloading" on screen is the title,
      // asserted above, since a heading over a lone group says nothing.
      expect(pressableRows(), findsNWidgets(2));

      // Pressing one drops that download and its part-file -- what the
      // notification's "Cancel all" does -- closes the popup, and says so.
      await tester.tap(find.byKey(SharingStopDialog.cancelKey('tt1:tt1')));
      await tester.pumpAndSettle();

      expect(downloads.removed, [(key: 'tt1:tt1', deleteFiles: true)]);
      expect(find.byType(SharingStopDialog), findsNothing);
      expect(find.text('Deleted Alien.'), findsOneWidget);
      // The setting was never touched: this stop was about the download.
      expect(s.prefs.shareWhileIdle, isTrue);
      expect(s.policy.pausedForRun, isFalse);
    });

    testWidgets('a cancel the server refuses is said, not swallowed', (
      tester,
    ) async {
      final downloads = downloadsOf([download('tt1', 'Alien')])
        ..removeError = StateError('server is not running');
      await openPopup(
        tester,
        reading: traffic(down: true),
        downloads: downloads,
      );

      await tester.tap(find.byKey(SharingStopDialog.cancelKey('tt1:tt1')));
      await tester.pumpAndSettle();

      expect(find.byType(SharingStopDialog), findsNothing);
      expect(find.text(SharingStopDialog.cancelFailed), findsOneWidget);
    });

    testWidgets('while downloading with no offline download in flight, says '
        'so and offers the sharing stops, which govern it', (tester) async {
      // The other thing the server downloads with nothing playing: a title
      // that was watched, finishing the file it was streamed from. That
      // torrent is paused when the setting is off, so the sharing rows are
      // the stop that works, and the statement says why they are there.
      final s = await openPopup(
        tester,
        reading: traffic(down: true),
        downloads: downloadsOf([
          download('tt3', 'Alien 3', state: DownloadState.complete),
        ]),
      );

      expect(find.text('Downloading'), findsOneWidget);
      expect(find.byKey(SharingStopDialog.noDownloadKey), findsOneWidget);
      expect(
        find.text(SharingStopDialog.noDownloadDescription),
        findsOneWidget,
      );
      expect(find.byKey(SharingStopDialog.notNowKey), findsOneWidget);
      expect(find.byKey(SharingStopDialog.stopKey), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is ListTile && w.key.toString().contains('sharing-cancel'),
        ),
        findsNothing,
      );
      expect(pressableRows(), findsNWidgets(2));

      await tester.tap(find.byKey(SharingStopDialog.notNowKey));
      await tester.pumpAndSettle();
      await s.policy.settled;
      expect(s.settings.patches.last, {IdleSharing.seedingEnabledKey: false});
      expect(s.policy.pausedForRun, isTrue);
    });

    testWidgets('a downloads listing that fails reads as no download in '
        'flight', (tester) async {
      // All the app knows then is that bytes are coming in; it says that
      // and offers the stops it can stand behind, rather than a Cancel for
      // a download it could not see.
      final downloads = downloadsOf([download('tt1', 'Alien')])
        ..listError = StateError('server is not running');
      await openPopup(
        tester,
        reading: traffic(down: true),
        downloads: downloads,
      );

      expect(find.byKey(SharingStopDialog.noDownloadKey), findsOneWidget);
      expect(find.byKey(SharingStopDialog.cancelKey('tt1:tt1')), findsNothing);
      expect(find.byKey(SharingStopDialog.notNowKey), findsOneWidget);
    });

    testWidgets('while both, offers both groups under headings', (
      tester,
    ) async {
      final downloads = downloadsOf([download('tt1', 'Alien')]);
      final s = await openPopup(
        tester,
        reading: traffic(up: true, down: true),
        downloads: downloads,
      );

      expect(find.text('Uploading and downloading'), findsOneWidget);
      expect(find.text(SharingStopDialog.uploadingHeading), findsOneWidget);
      expect(find.text(SharingStopDialog.downloadingHeading), findsOneWidget);
      expect(find.byKey(SharingStopDialog.notNowKey), findsOneWidget);
      expect(find.byKey(SharingStopDialog.stopKey), findsOneWidget);
      expect(
        find.byKey(SharingStopDialog.cancelKey('tt1:tt1')),
        findsOneWidget,
      );
      expect(pressableRows(), findsNWidgets(3));
      // The headings are in order: the up arrow's group above the down
      // arrow's, as the label names them.
      expect(
        tester.getTopLeft(find.text(SharingStopDialog.uploadingHeading)).dy,
        lessThan(
          tester.getTopLeft(find.text(SharingStopDialog.downloadingHeading)).dy,
        ),
      );

      // Each group's stop still does its own thing from here.
      await tester.tap(find.byKey(SharingStopDialog.stopKey));
      await tester.pumpAndSettle();
      await s.policy.settled;
      expect(s.prefs.shareWhileIdle, isFalse);
      expect(downloads.removed, isEmpty);
    });

    testWidgets('while both with the setting off, the sharing group says so '
        'and the download group is still a stop', (tester) async {
      final downloads = downloadsOf([download('tt1', 'Alien')]);
      await openPopup(
        tester,
        sharing: false,
        reading: traffic(up: true, down: true),
        downloads: downloads,
      );

      expect(find.byKey(SharingStopDialog.alreadyOffKey), findsOneWidget);
      expect(
        find.byKey(SharingStopDialog.cancelKey('tt1:tt1')),
        findsOneWidget,
      );
      final pressable = pressableRows();
      expect(pressable, findsOneWidget);
      expect(
        tester.widget<ListTile>(pressable).key,
        SharingStopDialog.cancelKey('tt1:tt1'),
      );
    });
  });

  group('the settings tile', () {
    /// The switch alone, under a scope holding [policy].
    Future<void> pumpTile(
      WidgetTester tester, {
      required IdleSharingPolicy policy,
      required AppPrefs prefs,
    }) async {
      await tester.pumpWidget(
        DeviceScope(
          profile: phone,
          child: PrefsScope(
            prefs: prefs,
            child: SharingScope(
              policy: policy,
              monitor: SharingActivityMonitor(client: FakeSharingActivity()),
              child: MaterialApp(
                home: Scaffold(body: IdleSharingSection(prefs: prefs)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// A policy over preferences that persist nothing, started.
    IdleSharingPolicy startedPolicy(AppPrefs prefs) {
      final policy = IdleSharingPolicy(
        prefs: prefs,
        server: RecordingServerSettings(),
      );
      addTearDown(policy.dispose);
      return policy..start();
    }

    testWidgets('says so while a "Not now" is holding the sharing off', (
      tester,
    ) async {
      final prefs = AppPrefs.inMemory();
      final policy = startedPolicy(prefs);
      await pumpTile(tester, policy: policy, prefs: prefs);
      expect(find.textContaining(IdleSharing.pausedNote), findsNothing);

      // What the popup's "Not now" does, while this tile is on screen --
      // which is where it is pressed from, since the light is drawn over
      // the Settings tab like every other. No second mount: a tile that
      // only says this after the tab is left and opened again is showing a
      // switch that is on over a run in which nothing is being shared.
      policy.pauseUntilRestart();
      await tester.pump();

      // The switch is still on -- that is what "Not now" means -- so the
      // tile has to say why nothing is being shared, or it is describing
      // something the app is not doing.
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(settingKey(AppPrefs.shareWhileIdleKey)),
            )
            .value,
        isTrue,
      );
      expect(find.textContaining(IdleSharing.pausedNote), findsOneWidget);
    });

    testWidgets('never says so under a switch that was off first', (
      tester,
    ) async {
      // The other order to the test below: the switch off first, the
      // "Not now" second. The popup does not draw that row in this state
      // and the policy refuses the pause anyway, so the tile has nothing
      // to say -- "Paused until you next start Xtremio." under a switch
      // that is off promises a resumption that is never coming, whichever
      // way round the two presses arrive.
      final prefs = AppPrefs.inMemory();
      await prefs.setShareWhileIdle(false);
      final policy = startedPolicy(prefs);
      await pumpTile(tester, policy: policy, prefs: prefs);

      policy.pauseUntilRestart();
      await tester.pump();

      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(settingKey(AppPrefs.shareWhileIdleKey)),
            )
            .value,
        isFalse,
      );
      expect(policy.pausedForRun, isFalse);
      expect(find.textContaining(IdleSharing.pausedNote), findsNothing);
    });

    testWidgets('stops saying so once the switch is off', (tester) async {
      final prefs = AppPrefs.inMemory();
      final policy = startedPolicy(prefs);
      await pumpTile(tester, policy: policy, prefs: prefs);
      policy.pauseUntilRestart();
      await tester.pump();
      expect(find.textContaining(IdleSharing.pausedNote), findsOneWidget);

      await prefs.setShareWhileIdle(false);
      await tester.pump();

      // "Paused until you next start Xtremio" under a switch that is off
      // promises a resumption that is never coming, since the setting will
      // still be off at that start. The switch is the longer of the two
      // stops and the tile is left saying that and nothing else.
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(settingKey(AppPrefs.shareWhileIdleKey)),
            )
            .value,
        isFalse,
      );
      expect(find.textContaining(IdleSharing.pausedNote), findsNothing);
    });
  });

  group('what it says', () {
    test('one glyph and one label per direction, none when dark', () {
      expect(SharingLight.glyphFor(traffic(up: true)), Icons.upload_outlined);
      expect(
        SharingLight.glyphFor(traffic(down: true)),
        Icons.download_outlined,
      );
      expect(
        SharingLight.glyphFor(traffic(up: true, down: true)),
        Icons.swap_vert,
      );
      expect(SharingLight.glyphFor(traffic()), isNull);
      expect(SharingLight.glyphFor(BackgroundTraffic.none), isNull);

      expect(
        SharingLight.labelFor(traffic(up: true)),
        'Uploading to other people',
      );
      expect(SharingLight.labelFor(traffic(down: true)), 'Downloading');
      expect(
        SharingLight.labelFor(traffic(up: true, down: true)),
        'Uploading and downloading',
      );
    });
  });
}
