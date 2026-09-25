import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/diagnostics/diagnostics_report.dart';
import 'package:xtremio/features/drive/drive_pairing_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/external_link.dart';

import '../support/diagnostics_capture.dart';
import '../support/fake_drive_pairing_service.dart';
import '../support/fake_link_opener.dart';
import '../support/fake_secret_store.dart';

const DeviceProfile _tv = DeviceProfile(isTv: true, hasTouch: false);
const DeviceProfile _phone = DeviceProfile(isTv: false, hasTouch: true);
const DeviceProfile _desktop = DeviceProfile(isTv: false, hasTouch: false);

/// A [DriveAccount] over fakes, with the preferences loaded first the way
/// the app loads them.
Future<DriveAccount> _account({FakeSecretStore? secrets}) async {
  final prefs = AppPrefs.inMemory();
  await prefs.load();
  final account = DriveAccount(
    prefs: prefs,
    secrets: secrets ?? FakeSecretStore(),
    now: () => pairingNow,
  );
  await account.load();
  addTearDown(() {
    account.dispose();
    prefs.dispose();
  });
  return account;
}

Widget _harness({
  required bool isTv,
  required DrivePairingService service,
  required DriveAccount account,
  ExternalLinkOpener? opener,
}) => DeviceScope(
  profile: isTv ? _tv : _phone,
  child: ExternalLinkScope(
    opener: opener ?? FakeLinkOpener(),
    child: DriveAccountScope(
      account: account,
      child: MaterialApp(
        home: DrivePairingScreen(service: service, now: () => pairingNow),
      ),
    ),
  ),
);

/// One polling interval, and a frame to draw what it brought back.
Future<void> _tick(WidgetTester tester, {int times = 1}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(DrivePairingScreen.defaultPollEvery);
    await tester.pump();
  }
}

void main() {
  group('the two shapes', () {
    testWidgets('a television draws the QR for the link, and nothing else', (
      tester,
    ) async {
      final service = FakeDrivePairingService();
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: await _account()),
      );
      await tester.pump();

      expect(find.text(DrivePairingScreen.scanHeading), findsOneWidget);
      final qr = tester.widget<PairingQrCode>(find.byType(PairingQrCode));
      expect(qr.link, service.session.link);
      expect(find.text(DrivePairingScreen.waitingMessage), findsOneWidget);
      // And it says it is a television: this viewer is looking at the screen
      // the QR is on, so the pick page hands nobody back and words its
      // confirmation for somebody who will read it on the other screen.
      expect(service.shapes, [DrivePairingShape.television]);
    });

    testWidgets('a phone opens the page itself and draws no QR at all', (
      tester,
    ) async {
      // There is no second device to scan with, and scanning your own
      // screen is absurd.
      final service = FakeDrivePairingService();
      final opener = FakeLinkOpener();
      await tester.pumpWidget(
        _harness(
          isTv: false,
          service: service,
          account: await _account(),
          opener: opener,
        ),
      );
      await tester.pump();

      expect(find.byType(PairingQrCode), findsNothing);
      expect(find.text(DrivePairingScreen.browserHeading), findsOneWidget);
      expect(opener.opened.map((url) => url.toString()), [
        service.session.link,
      ]);
      // And it says it is a phone, which is the one shape that is handed
      // back to: the pick page ends by navigating to
      // `drivePairingHandBackLink`, which brings this app to the front.
      expect(service.shapes, [DrivePairingShape.phone]);
      expect(DrivePairingShape.phone.handsBack, isTrue);
    });

    testWidgets('a desktop opens the page too, and says it is a desktop', (
      tester,
    ) async {
      // `hasTouch` is what tells a phone from a desktop among the shapes that
      // are not televisions, and the desktop is where the `stremio://`
      // registration is installed by hand or not at all
      // (`docs/DEEP_LINKS.md`) -- so a hand-back there could put a browser on
      // an error page where a confirmation should be.
      //
      // It is still not a television, and the service is told so rather than
      // being left to infer it from the missing hand-back: the pick page tells
      // a desktop its files are in the app and the window can be closed, and
      // told a television's viewer to look at their television.
      final service = FakeDrivePairingService();
      final opener = FakeLinkOpener();
      await tester.pumpWidget(
        DeviceScope(
          profile: _desktop,
          child: ExternalLinkScope(
            opener: opener,
            child: DriveAccountScope(
              account: await _account(),
              child: MaterialApp(
                home: DrivePairingScreen(
                  service: service,
                  now: () => pairingNow,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(opener.opened, hasLength(1));
      expect(service.shapes, [DrivePairingShape.desktop]);
      expect(DrivePairingShape.desktop.handsBack, isFalse);
    });

    testWidgets('and it opens an external browser, never an in-app web view', (
      tester,
    ) async {
      // The one assertion that has to be about the launch *mode*: Google
      // answers `disallowed_useragent` to OAuth in an embedded web view, so
      // `LaunchMode.inAppWebView` would not fail visibly here -- it would
      // fail on the sign-in page, on a phone, with nothing in this suite to
      // say so. The real opener is used rather than a fake, because the
      // mode is the real opener's to choose.
      final launched = <Uri>[];
      final modes = <LaunchMode>[];
      final service = FakeDrivePairingService();
      await tester.pumpWidget(
        _harness(
          isTv: false,
          service: service,
          account: await _account(),
          opener: UrlLauncherLinkOpener(
            launch: (url, {required mode}) async {
              launched.add(url);
              modes.add(mode);
              return true;
            },
          ),
        ),
      );
      await tester.pump();

      expect(launched.map((url) => url.toString()), [service.session.link]);
      expect(modes, [LaunchMode.externalApplication]);

      // And the button that opens it again -- a launch that did not take, a
      // tab the viewer closed -- goes the same way.
      await tester.tap(find.text(DrivePairingScreen.openAgainLabel));
      await tester.pump();
      expect(modes, [
        LaunchMode.externalApplication,
        LaunchMode.externalApplication,
      ]);
    });
  });

  group('the polling', () {
    testWidgets('stops on success, and the session is read exactly once '
        'after it is ready', (tester) async {
      final service = FakeDrivePairingService(
        answers: [
          const DrivePairingWaiting(signedIn: false),
          const DrivePairingWaiting(signedIn: true),
          fakeCollected(),
          // What a second read would get. If the screen ever makes one,
          // this is what it would find -- and the expectations below would
          // catch the screen believing it.
          const DrivePairingGone(),
        ],
      );
      final account = await _account();
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: account),
      );
      await tester.pump();
      expect(service.collects, isEmpty);

      await _tick(tester);
      expect(find.text(DrivePairingScreen.waitingMessage), findsOneWidget);
      await _tick(tester);
      expect(find.text(DrivePairingScreen.signedInMessage), findsOneWidget);

      await _tick(tester);
      expect(service.collects.length, 3);
      expect(account.state, DriveLinkState.linked);

      // And now nothing more is asked, however long the screen stands
      // there: the fourth answer above is never fetched.
      await _tick(tester, times: 10);
      expect(service.collects.length, 3);
      expect(account.state, DriveLinkState.linked);
    });

    testWidgets('stops when the window closes, and offers a fresh code', (
      tester,
    ) async {
      final service = FakeDrivePairingService();
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: await _account()),
      );
      await tester.pump();

      await tester.pump(DrivePairingScreen.sessionWindow);
      await tester.pump();
      expect(find.text(DrivePairingScreen.expiredMessage), findsOneWidget);
      expect(find.byType(PairingQrCode), findsNothing);

      final asked = service.collects.length;
      await _tick(tester, times: 10);
      expect(
        service.collects.length,
        asked,
        reason: 'a screen that says the code is dead is still asking about it',
      );

      // A way on rather than a dead end -- and a press, not a timer: the
      // call that opens a session is the rate-limited one.
      expect(service.opens, 1);
      await tester.tap(find.text(DrivePairingScreen.freshCodeLabel));
      await tester.pump();
      await tester.pump();
      expect(service.opens, 2);
      expect(find.byType(PairingQrCode), findsOneWidget);
      await _tick(tester);
      expect(service.collects.length, greaterThan(asked));
    });

    testWidgets("stops when the service's own 410 says the session is gone", (
      tester,
    ) async {
      final service = FakeDrivePairingService(
        answers: [const DrivePairingExpired()],
      );
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: await _account()),
      );
      await tester.pump();

      await _tick(tester);
      expect(find.text(DrivePairingScreen.expiredMessage), findsOneWidget);
      await _tick(tester, times: 5);
      expect(service.collects.length, 1);
    });

    testWidgets('stops when the screen goes away', (tester) async {
      // A timer that outlives its screen keeps a television talking to a
      // service about a pairing nobody is waiting for.
      final service = FakeDrivePairingService();
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: await _account()),
      );
      await tester.pump();
      await _tick(tester, times: 2);
      expect(service.collects.length, 2);

      await tester.pumpWidget(const SizedBox.shrink());
      await _tick(tester, times: 10);
      expect(service.collects.length, 2);
    });

    testWidgets('a poll that could not be made is not a verdict', (
      tester,
    ) async {
      // A television drops off its wifi and comes back. Giving up on the
      // first failed poll would be a pairing that fails whenever the room's
      // router is busy; the window is the bound, not a count of failures.
      final service = FakeDrivePairingService(
        answers: [
          const DrivePairingUnreachable(),
          const DrivePairingUnreachable(),
          fakeCollected(),
        ],
      );
      final account = await _account();
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: account),
      );
      await tester.pump();

      await _tick(tester, times: 3);
      expect(account.state, DriveLinkState.linked);
    });
  });

  group('the three outcomes', () {
    testWidgets('linked: the file is recorded and the account has a '
        'credential', (tester) async {
      final secrets = FakeSecretStore();
      final account = await _account(secrets: secrets);
      final service = FakeDrivePairingService(answers: [fakeCollected()]);
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: account),
      );
      await tester.pump();
      await _tick(tester);

      expect(account.state, DriveLinkState.linked);
      expect(account.files.entries.single.fileId, 'drive-file-1');
      expect(account.files.entries.single.name, 'Arrival (2016) 2160p.mkv');
      expect(account.files.entries.single.mimeType, 'video/x-matroska');
      expect(account.files.entries.single.linkedAt, pairingNow);
      // The credential reached the platform's store, and the screen names
      // the file rather than anything about the token.
      expect(secrets.stored[DriveAccount.refreshTokenKey], fakeRefreshToken);
      expect(find.textContaining('Arrival (2016) 2160p.mkv'), findsOneWidget);
      expect(find.text(DrivePairingScreen.thisRunOnlyMessage), findsNothing);
      // One file names itself, and there is one press to play it.
      expect(
        find.text(
          DrivePairingScreen.linkedHeadline(const ['Arrival (2016) 2160p.mkv']),
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Play'), findsOneWidget);
    });

    testWidgets('linked: every file picked in one session arrives', (
      tester,
    ) async {
      // One scan, a whole season. The Picker takes several files at once and
      // a pairing carries all of them, in the order they were picked, under
      // the one credential and in one write.
      final secrets = FakeSecretStore();
      final account = await _account(secrets: secrets);
      final collected = fakeCollectedFiles();
      final service = FakeDrivePairingService(answers: [collected]);
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: account),
      );
      await tester.pump();
      await _tick(tester);

      expect(account.state, DriveLinkState.linked);
      expect(account.files.entries.map((file) => file.fileId), [
        'drive-file-1',
        'drive-file-2',
        'drive-file-3',
      ]);
      expect(
        account.files.entries.map((file) => file.name),
        collected.files.map((file) => file.name),
      );
      // One pairing, one moment: they became reachable together.
      expect(
        account.files.entries.map((file) => file.linkedAt),
        everyElement(pairingNow),
      );
      // And one credential for all of them, written once.
      expect(secrets.stored[DriveAccount.refreshTokenKey], fakeRefreshToken);

      // The screen counts them rather than stacking twelve filenames at a
      // viewer in an armchair, and offers a row per file instead of a Play
      // button that would have to guess which one.
      expect(find.text('3 files are linked.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Play'), findsNothing);
      for (final file in collected.files) {
        expect(find.byKey(Key('drive-file-${file.fileId}')), findsOneWidget);
      }
    });

    testWidgets('expired: the window closed and nothing was linked', (
      tester,
    ) async {
      final account = await _account();
      final service = FakeDrivePairingService(
        answers: [const DrivePairingExpired()],
      );
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: account),
      );
      await tester.pump();
      await _tick(tester);

      expect(find.text(DrivePairingScreen.expiredMessage), findsOneWidget);
      expect(account.state, DriveLinkState.unlinked);
      expect(account.files.isEmpty, isTrue);
    });

    testWidgets('refused: a session that is not there any more', (
      tester,
    ) async {
      final account = await _account();
      final gone = FakeDrivePairingService(answers: [const DrivePairingGone()]);
      await tester.pumpWidget(
        _harness(isTv: true, service: gone, account: account),
      );
      await tester.pump();
      await _tick(tester);
      expect(find.text(DrivePairingScreen.lostMessage), findsOneWidget);
      expect(account.state, DriveLinkState.unlinked);
      expect(find.text(DrivePairingScreen.freshCodeLabel), findsOneWidget);
    });

    testWidgets('and refused: a session that could never be opened', (
      tester,
    ) async {
      // The other half of refused, and the one that never polls at all:
      // sixty sessions an hour per address is the cost limit the service
      // lives behind, and a screen that spun instead of saying so would
      // look exactly like a network fault.
      final busy = FakeDrivePairingService(
        openings: const [
          DrivePairingUnavailable(XtremioDrivePairingService.tooManyCodes),
        ],
      );
      await tester.pumpWidget(
        _harness(isTv: true, service: busy, account: await _account()),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.text(XtremioDrivePairingService.tooManyCodes),
        findsOneWidget,
      );
      expect(find.text(DrivePairingScreen.freshCodeLabel), findsOneWidget);
      expect(find.byType(PairingQrCode), findsNothing);
      expect(busy.collects, isEmpty);
    });

    testWidgets('and thisRunOnly is said out loud rather than swallowed', (
      tester,
    ) async {
      // A Linux box with no keyring daemon, an Android keystore that will
      // not unwrap its key: the pairing works now and is gone after a
      // restart, and a screen that showed a plain tick would be telling the
      // viewer something untrue about the evening after this one.
      final account = await _account(secrets: FakeSecretStore.failing());
      final service = FakeDrivePairingService(answers: [fakeCollected()]);
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: account),
      );
      await tester.pump();
      await _tick(tester);

      expect(account.state, DriveLinkState.linked);
      expect(account.thisRunOnly, isTrue);
      expect(find.text(DrivePairingScreen.thisRunOnlyMessage), findsOneWidget);
    });
  });

  group('the one-shot read', () {
    testWidgets('a slow answer is never overtaken by the next poll', (
      tester,
    ) async {
      // The read that finds a ready session deletes it, so a second read
      // issued while the first is still coming back is the `404` that loses
      // the pairing -- and which of the two the screen happens to look at
      // last decides what the viewer sees. The timer is therefore armed
      // when an answer is in, never `Timer.periodic`.
      final service = FakeDrivePairingService();
      final holding = Completer<DrivePairingAnswer>();
      service.hold = holding;
      final account = await _account();
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: account),
      );
      await tester.pump();

      await tester.pump(DrivePairingScreen.defaultPollEvery);
      expect(service.collects.length, 1);
      await _tick(tester, times: 5);
      expect(
        service.collects.length,
        1,
        reason:
            'five intervals passed with one read still out, and the '
            'screen made five more',
      );

      holding.complete(fakeCollected());
      await tester.pump();
      await tester.pump();
      expect(account.state, DriveLinkState.linked);
      expect(service.collects.length, 1);
    });

    testWidgets('an answer about a session the screen has left behind '
        'changes nothing', (tester) async {
      final service = FakeDrivePairingService();
      final holding = Completer<DrivePairingAnswer>();
      service.hold = holding;
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: await _account()),
      );
      await tester.pump();
      await tester.pump(DrivePairingScreen.defaultPollEvery);
      expect(service.collects.length, 1);

      // The window closes with that read still out.
      await tester.pump(DrivePairingScreen.sessionWindow);
      await tester.pump();
      expect(find.text(DrivePairingScreen.expiredMessage), findsOneWidget);

      holding.complete(const DrivePairingWaiting(signedIn: true));
      await tester.pump();
      await tester.pump();
      expect(find.text(DrivePairingScreen.expiredMessage), findsOneWidget);
      expect(find.text(DrivePairingScreen.signedInMessage), findsNothing);
      final asked = service.collects.length;
      await _tick(tester, times: 5);
      expect(service.collects.length, asked);
    });

    testWidgets('and one about the session before this one does not end it', (
      tester,
    ) async {
      // A fresh code, asked for while the dead session's last read was
      // still out. That read then says the old session is gone -- which it
      // is, and which says nothing at all about the code now on screen --
      // which is why the answer is matched against the session it was asked
      // about and not merely against the screen still waiting.
      final service = FakeDrivePairingService(
        openings: [
          DrivePairingOpened(fakeSession()),
          DrivePairingOpened(fakeSession(id: 'session-2')),
        ],
      );
      final holding = Completer<DrivePairingAnswer>();
      service.hold = holding;
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: await _account()),
      );
      await tester.pump();
      await tester.pump(DrivePairingScreen.defaultPollEvery);
      await tester.pump(DrivePairingScreen.sessionWindow);
      await tester.pump();
      expect(find.text(DrivePairingScreen.expiredMessage), findsOneWidget);

      await tester.tap(find.text(DrivePairingScreen.freshCodeLabel));
      await tester.pump();
      await tester.pump();
      // The QR is the second session's, which is what the link in it says.
      String drawn() =>
          tester.widget<PairingQrCode>(find.byType(PairingQrCode)).link;
      expect(drawn(), contains('session-2'));

      holding.complete(const DrivePairingGone());
      await tester.pump();
      await tester.pump();
      expect(drawn(), contains('session-2'));
      expect(find.text(DrivePairingScreen.lostMessage), findsNothing);
    });

    testWidgets('a pairing collected as the screen goes away is still '
        'stored', (tester) async {
      // The read that answers `ready` deletes the session, so the answer in
      // flight is the only copy of the credential. Dropping it because the
      // viewer pressed Back half a second early loses a pairing they really
      // did complete -- and there is nothing to poll for afterwards.
      final service = FakeDrivePairingService();
      final holding = Completer<DrivePairingAnswer>();
      service.hold = holding;
      final account = await _account();
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: account),
      );
      await tester.pump();
      await tester.pump(DrivePairingScreen.defaultPollEvery);
      expect(service.collects.length, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      holding.complete(fakeCollected());
      await tester.pump();
      await tester.pump();

      expect(account.state, DriveLinkState.linked);
      expect(account.files.entries.single.fileId, 'drive-file-1');
      // And nothing else was asked for: the session is gone.
      await _tick(tester, times: 5);
      expect(service.collects.length, 1);
    });

    testWidgets('and a fresh code asked for over a pairing already in flight '
        'does not throw it away', (tester) async {
      final service = FakeDrivePairingService();
      final holding = Completer<DrivePairingAnswer>();
      service.hold = holding;
      final account = await _account();
      await tester.pumpWidget(
        _harness(isTv: true, service: service, account: account),
      );
      await tester.pump();
      await tester.pump(DrivePairingScreen.sessionWindow);
      await tester.pump();
      expect(find.text(DrivePairingScreen.expiredMessage), findsOneWidget);

      // The window closed while a read was out, and that read turns out to
      // have collected the pairing. It is honoured: whatever the screen
      // moved on to, the service deleted that session and this is what came
      // back from it.
      holding.complete(fakeCollected());
      await tester.pump();
      await tester.pump();
      expect(account.state, DriveLinkState.linked);
      expect(find.textContaining('Arrival (2016) 2160p.mkv'), findsOneWidget);
    });
  });

  testWidgets('the token appears in no widget, no log and no report', (
    tester,
  ) async {
    final lines = captureDiagnostics();
    final account = await _account();
    final service = FakeDrivePairingService(answers: [fakeCollected()]);
    await tester.pumpWidget(
      _harness(isTv: true, service: service, account: account),
    );
    await tester.pump();
    await _tick(tester);
    expect(account.state, DriveLinkState.linked);

    // Every string this screen drew, including the one it drew about the
    // pairing that has just succeeded.
    final drawn = [
      for (final text in tester.widgetList<Text>(find.byType(Text)))
        '${text.data ?? ''} ${text.textSpan?.toPlainText() ?? ''}',
    ].join('\n');
    expect(drawn, isNot(contains(fakeRefreshToken)));
    expect(drawn, contains('Arrival (2016) 2160p.mkv'));

    // The log ring, and the whole diagnostics dump built out of it.
    expect(lines.join('\n'), isNot(contains(fakeRefreshToken)));
    expect(
      redactSecrets(
        '${lines.join('\n')}\n$drawn\n${service.session.link}\n'
        'drive-refresh-token: $fakeRefreshToken',
      ),
      isNot(contains(fakeRefreshToken)),
    );

    // And the objects themselves, since a `$answer` in a debug line is how
    // a secret usually gets filed.
    expect('${fakeCollected()}', isNot(contains(fakeRefreshToken)));
    expect('${service.session}', isNot(contains(fakeRefreshToken)));
  });

  group('what the screen says about what arrived', () {
    // One file is still the common case, and a sentence that read oddly in
    // the singular would be a worse regression than the missing capability.
    test('names one file', () {
      expect(
        DrivePairingScreen.linkedHeadline(const ['Arrival.mkv']),
        '"Arrival.mkv" is linked.',
      );
    });

    test('counts several', () {
      expect(
        DrivePairingScreen.linkedHeadline(const ['a.mkv', 'b.mkv']),
        '2 files are linked.',
      );
    });

    test('and falls back when the Picker sent no name', () {
      // A nameless file draws the wording a nameless single file has always
      // had, rather than a pair of empty quotes.
      expect(
        DrivePairingScreen.linkedHeadline(const ['']),
        'That file is '
        'linked.',
      );
      expect(
        DrivePairingScreen.linkedHeadline(const []),
        'That file is '
        'linked.',
      );
    });

    test('and every waiting line says several may be picked', () {
      // Multiselect is not discoverable in the Picker: a viewer who is not
      // told picks one file and presses the button.
      expect(DrivePairingScreen.signedInMessage, contains('more than one'));
      expect(DrivePairingScreen.inBrowserMessage, contains('more than one'));
    });
  });

  group('the session window', () {
    // A length and not a deadline: the service's `expiresAt` is on its
    // clock and `now` is on a television's, which is set by whatever DHCP
    // handed it.
    test('is what the service says when the two clocks agree', () {
      expect(
        DrivePairingScreen.windowOf(fakeSession(), pairingNow),
        const Duration(minutes: 10),
      );
      expect(
        DrivePairingScreen.windowOf(
          fakeSession(lasts: const Duration(minutes: 4)),
          pairingNow,
        ),
        const Duration(minutes: 4),
      );
    });

    test('is capped when the television thinks it is hours ago', () {
      // A set running two hours slow would otherwise read the window as two
      // hours and ten minutes, and poll all evening for a session the
      // service dropped after ten.
      expect(
        DrivePairingScreen.windowOf(
          fakeSession(),
          pairingNow.subtract(const Duration(hours: 2)),
        ),
        DrivePairingScreen.sessionWindow,
      );
    });

    test('and floored when it thinks it is hours hence', () {
      // The worse direction: a negative window would put "that code has
      // expired" over a code that works perfectly well, on the frame it was
      // drawn. The service's own 410 is what really ends a session.
      expect(
        DrivePairingScreen.windowOf(
          fakeSession(),
          pairingNow.add(const Duration(hours: 2)),
        ),
        DrivePairingScreen.shortestWindow,
      );
    });
  });
}
