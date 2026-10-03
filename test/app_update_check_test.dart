import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/update/release_version.dart';
import 'package:xtremio/features/update/update_dialog.dart';

import 'support/empty_board.dart';
import 'support/fake_downloads_client.dart';
import 'support/fake_prefs_client.dart';
import 'support/fake_sharing.dart';
import 'support/fake_updates.dart';

/// The daily look the app takes by itself: when it runs, and that its
/// dialog never comes up over a player.
void main() {
  Future<FakeReleaseSource> start(
    WidgetTester tester, {
    BuildIdentity identity = releaseBuild,
  }) async {
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    final prefs = AppPrefs(client: FakePrefsClient());
    final source = FakeReleaseSource(release: sampleRelease());
    await tester.pumpWidget(
      XtremioApp(
        core: emptyBoardCore(),
        downloads: downloads,
        prefs: prefs,
        sharingActivity: FakeSharingActivity(),
        updates: fakeUpdates(prefs: prefs, identity: identity, source: source),
      ),
    );
    await tester.pumpAndSettle();
    return source;
  }

  testWidgets('looks a while after start-up and offers what it found', (
    tester,
  ) async {
    final source = await start(tester);
    expect(source.asked, 0, reason: 'nothing in the way of start-up');
    await tester.pump(XtremioApp.updateCheckDelay);
    await tester.pumpAndSettle();
    expect(source.asked, 1);
    expect(find.byType(UpdateDialog), findsOneWidget);
  });

  for (final leave in ['popped', 'removed']) {
    testWidgets('neither looks nor offers while a player is up, and does '
        'both once it is $leave', (tester) async {
      final source = await start(tester);
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      final player = MaterialPageRoute<void>(
        settings: const RouteSettings(name: PlayerScreen.routeName),
        builder: (_) => const Scaffold(body: Text('a film')),
      );
      navigator.push(player);
      await tester.pumpAndSettle();
      await tester.pump(XtremioApp.updateCheckDelay);
      await tester.pumpAndSettle();
      expect(source.asked, 0);
      expect(find.byType(UpdateDialog), findsNothing);

      if (leave == 'popped') {
        navigator.pop();
      } else {
        navigator.removeRoute(player);
      }
      await tester.pumpAndSettle();
      expect(source.asked, 1);
      expect(find.byType(UpdateDialog), findsOneWidget);
    });
  }

  testWidgets('an answer that lands while a player is up waits for it', (
    tester,
  ) async {
    final source = await start(tester);
    source.gate = Completer<void>();
    await tester.pump(XtremioApp.updateCheckDelay);
    expect(source.asked, 1);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: PlayerScreen.routeName),
        builder: (_) => const Scaffold(body: Text('a film')),
      ),
    );
    await tester.pumpAndSettle();
    source.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(source.asked, 1);
  });

  testWidgets('a debug build asks nothing', (tester) async {
    final source = await start(tester, identity: debugBuild);
    await tester.pump(XtremioApp.updateCheckDelay * 2);
    await tester.pumpAndSettle();
    expect(source.asked, 0);
    expect(find.byType(UpdateDialog), findsNothing);
  });
}
