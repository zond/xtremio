import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// Where the details screen puts its spinner while it waits, on a
/// television and off one.
///
/// A television is watched from across the room, and a 16 dp spinner at
/// the far right of a heading is not something a viewer there sees as
/// "loading": the owner of a Chromecast reported the spinner "on the far
/// right corner, not in the middle of the screen". Whatever the screen is
/// waiting on -- the title, or every addon's answer -- the indicator sits
/// on the screen's centre line.
void main() {
  const phone = DeviceProfile(isTv: false, hasTouch: true);

  /// The screen under the app's own theme and, on a television, its
  /// `MediaQuery` (the text scale and the overscan band), which is what
  /// decides where the body's centre is.
  Widget harness(FakeCoreClient core, {required DeviceProfile device}) =>
      DeviceScope(
        profile: device,
        child: CoreScope(
          client: core,
          child: PlaybackScope(
            createEngine: FakePlaybackEngine.new,
            torrentStats: FakeTorrentStatsClient(),
            child: MaterialApp(
              theme: XtremioApp.themeFor(
                isTv: device.isTv,
                emphasis: FocusEmphasis.standard,
              ),
              builder: device.isTv ? TvMediaQuery.builder : null,
              home: const MetaDetailsScreen(type: 'movie', id: 'tt0063350'),
            ),
          ),
        ),
      );

  /// The movie fixture with every addon still answering.
  Map<String, dynamic> streamsLoading() {
    final fixture = loadMetaDetailsFixture();
    for (final group in fixture['streams'] as List<dynamic>) {
      (group as Map<String, dynamic>)['content'] = {'type': 'Loading'};
    }
    return fixture;
  }

  /// Mounts the screen over [state] (nothing at all: the title is still
  /// loading) and lets a spinner's animation not hold the pump.
  Future<void> pump(
    WidgetTester tester, {
    required DeviceProfile device,
    Map<String, dynamic>? state,
  }) async {
    useScreen(tester, tvSize);
    final core = FakeCoreClient(
      state: state == null ? const {} : {CoreField.metaDetails: state},
    );
    await tester.pumpWidget(harness(core, device: device));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  final spinner = find.byType(CircularProgressIndicator);

  for (final device in [tv, phone]) {
    final where = device.isTv ? 'on a television' : 'on a phone';

    testWidgets('while the title loads, the spinner is in the middle of the '
        'screen $where', (tester) async {
      await pump(tester, device: device);

      expect(spinner, findsOneWidget);
      final centre = tester.getCenter(spinner);
      // The body runs from the app bar to the bottom of the panel (less
      // the overscan band, on a television) and the spinner is in the
      // middle of it, on the screen's own centre line.
      final body = tester.getRect(
        find.ancestor(of: spinner, matching: find.byType(Center)),
      );
      final bar = tester.getRect(find.byType(AppBar));
      expect(body.top, closeTo(bar.bottom, 1));
      expect(body.center.dx, closeTo(tvSize.width / 2, 1));
      expect(body.center.dy, greaterThan(bar.bottom));
      expect(centre.dx, closeTo(body.center.dx, 2));
      expect(centre.dy, closeTo(body.center.dy, 2));
    });
  }

  testWidgets('while every addon is still answering, the one spinner on a '
      'television is on the centre line under the Streams heading, with '
      'the label the phone list carries', (tester) async {
    await pump(tester, device: tv, state: streamsLoading());

    expect(spinner, findsOneWidget);
    final centre = tester.getCenter(spinner);
    expect(centre.dx, closeTo(tvSize.width / 2, 2));
    final heading = tester.getRect(find.text('Streams'));
    expect(centre.dy, greaterThan(heading.bottom));
    expect(centre.dy, lessThan(tvSize.height));
    expect(find.text(kLookingForStreams), findsOneWidget);
  });

  testWidgets('a phone keeps the small spinner beside the Streams heading '
      'while the addons answer', (tester) async {
    await pump(tester, device: phone, state: streamsLoading());

    expect(spinner, findsOneWidget);
    final heading = tester.getRect(find.text('Streams'));
    final centre = tester.getCenter(spinner);
    expect(centre.dy, closeTo(heading.center.dy, heading.height));
    expect(find.text(kLookingForStreams), findsNothing);
  });
}
