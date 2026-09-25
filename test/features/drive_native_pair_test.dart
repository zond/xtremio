import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/drive/drive_native_pair_screen.dart';
import 'package:xtremio/shell/deep_link.dart';

import '../support/fake_drive_pairing_service.dart';

/// A picker that answers what a test tells it to, and counts being asked.
class FakeNativePicker implements DriveNativePicker {
  FakeNativePicker(this.answers);

  final List<DriveNativePickResult> answers;
  int picks = 0;

  @override
  Future<bool> available() async => true;

  @override
  Future<DriveNativePickResult> pick() async {
    picks++;
    return answers.length > 1 ? answers.removeAt(0) : answers.first;
  }
}

const picked = DriveNativePicked(
  // Not a real code and could not be: nothing in this suite holds one.
  serverAuthCode: 'fake-server-auth-code-for-tests-only',
  fileIds: ['drive-file-1', 'drive-file-2', 'drive-file-3'],
);

Widget harness({
  required DriveNativePicker picker,
  required DrivePairingService service,
  String session = 'session-1',
}) => MaterialApp(
  home: DriveNativePairScreen(
    sessionId: session,
    picker: picker,
    service: service,
  ),
);

void main() {
  group('the link a television draws', () {
    test('is recognised, and carries the session the phone must hand to', () {
      expect(
        drivePairingSessionOfLink(
          'https://xtremio-drive.web.app/link?s=abc-123',
        ),
        'abc-123',
      );
      // `cleanUrls` serves the page at both spellings and a camera may read
      // either.
      expect(
        drivePairingSessionOfLink(
          'https://xtremio-drive.web.app/link.html?s=abc-123',
        ),
        'abc-123',
      );
    });

    test('and nothing else is', () {
      // Every one of these is a link some other thing in the world may send
      // this app, and none of them is a pairing. A lookalike host is the one
      // that matters: App Links verification is per host, and this parser is
      // what decides what the app *acts* on.
      for (final link in [
        'https://xtremio-drive.web.app.evil.example/link?s=abc-123',
        'https://evil.example/link?s=abc-123',
        'http://xtremio-drive.web.app/link?s=abc-123',
        'https://xtremio-drive.web.app/link',
        'https://xtremio-drive.web.app/link?s=',
        'https://xtremio-drive.web.app/pick?s=abc-123',
        'https://xtremio-drive.web.app/',
        'stremio://community.example/manifest.json',
        'stremio:///pair',
        'not a url at all',
      ]) {
        expect(
          drivePairingSessionOfLink(link),
          isNull,
          reason: '$link is not a pairing link',
        );
      }
    });

    test('and the addon reading does not claim it either', () {
      // The two readings must not both answer: `_onDeepLink` tries the
      // pairing one first, and a `stremio://` manifest URL must still reach
      // the addon path untouched.
      expect(
        deepLinkAddonManifestUrl('https://xtremio-drive.web.app/link?s=a'),
        isNull,
      );
      expect(
        drivePairingSessionOfLink('stremio://community.example/manifest.json'),
        isNull,
      );
    });
  });

  group('the phone picks and hands over', () {
    testWidgets('as soon as the screen opens, with no button to press first', (
      tester,
    ) async {
      // The viewer got here by pointing a camera at a QR. A screen that asks
      // them to press something else first is a step for its own sake.
      final picker = FakeNativePicker([picked]);
      final service = FakeDrivePairingService();
      await tester.pumpWidget(harness(picker: picker, service: service));
      await tester.pump();
      expect(picker.picks, 1);

      await tester.pumpAndSettle();
      expect(service.handovers, [(sessionId: 'session-1', files: 3)]);
      expect(find.text(DriveNativePairScreen.linkedMessage(3)), findsOneWidget);
    });

    testWidgets('and says it for one file as well as for three', (
      tester,
    ) async {
      final picker = FakeNativePicker([
        const DriveNativePicked(
          serverAuthCode: 'fake-server-auth-code-for-tests-only',
          fileIds: ['drive-file-1'],
        ),
      ]);
      await tester.pumpWidget(
        harness(picker: picker, service: FakeDrivePairingService()),
      );
      await tester.pumpAndSettle();
      expect(find.text(DriveNativePairScreen.linkedMessage(1)), findsOneWidget);
      expect(find.textContaining('1 files'), findsNothing);
    });

    testWidgets('a cancelled pick hands nothing over and can be retried', (
      tester,
    ) async {
      // Backing out costs nothing: the session is still waiting and the
      // television is still showing its code.
      final picker = FakeNativePicker([
        const DriveNativePickCancelled(),
        picked,
      ]);
      final service = FakeDrivePairingService();
      await tester.pumpWidget(harness(picker: picker, service: service));
      await tester.pumpAndSettle();
      expect(service.handovers, isEmpty);
      expect(find.text(DriveNativePairScreen.cancelledMessage), findsOneWidget);

      await tester.tap(find.text(DriveNativePairScreen.tryAgainLabel));
      await tester.pumpAndSettle();
      expect(picker.picks, 2);
      expect(service.handovers, [(sessionId: 'session-1', files: 3)]);
    });

    testWidgets('a phone with no native picker is sent to the web page', (
      tester,
    ) async {
      // Not an error: it is where every phone without this app already goes.
      await tester.pumpWidget(
        harness(
          picker: FakeNativePicker([const DriveNativePickUnavailable()]),
          service: FakeDrivePairingService(),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(DriveNativePairScreen.unavailableMessage),
        findsOneWidget,
      );
    });

    testWidgets('a session that has expired says so, and is not retried into '
        'a second spent code', (tester) async {
      final picker = FakeNativePicker([picked]);
      final service = FakeDrivePairingService()
        ..handoverAnswers = [DrivePairingHandover.gone];
      await tester.pumpWidget(harness(picker: picker, service: service));
      await tester.pumpAndSettle();
      expect(find.text(DriveNativePairScreen.goneMessage), findsOneWidget);

      // The code is one-time. Pressing again must not spend a second one on
      // a session that is not there any more.
      await tester.tap(find.text(DriveNativePairScreen.tryAgainLabel));
      await tester.pumpAndSettle();
      expect(picker.picks, 1, reason: 'the pick is not run again');
      expect(service.handovers, hasLength(1));
    });

    testWidgets('but a service that could not be reached can be', (
      tester,
    ) async {
      // Nothing is known to have been spent, so a fresh pick -- and a fresh
      // code with it -- is the right offer.
      final picker = FakeNativePicker([picked, picked]);
      final service = FakeDrivePairingService()
        ..handoverAnswers = [
          DrivePairingHandover.unreachable,
          DrivePairingHandover.taken,
        ];
      await tester.pumpWidget(harness(picker: picker, service: service));
      await tester.pumpAndSettle();
      expect(
        find.text(DriveNativePairScreen.unreachableMessage),
        findsOneWidget,
      );

      await tester.tap(find.text(DriveNativePairScreen.tryAgainLabel));
      await tester.pumpAndSettle();
      expect(picker.picks, 2);
      expect(find.text(DriveNativePairScreen.linkedMessage(3)), findsOneWidget);
    });

    testWidgets('the credential is on no screen', (tester) async {
      await tester.pumpWidget(
        harness(
          picker: FakeNativePicker([picked]),
          service: FakeDrivePairingService(),
        ),
      );
      await tester.pumpAndSettle();
      final drawn = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? '')
          .join('\n');
      expect(drawn, isNot(contains('fake-server-auth-code-for-tests-only')));
      // Nor the ids, which are not secret but are not a viewer's business
      // either -- they see names, on the television.
      expect(drawn, isNot(contains('drive-file-1')));
    });
  });
}
