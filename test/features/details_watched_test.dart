import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/face_buttons.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/tv_meta_header.dart';
import 'package:xtremio/features/details/watched_button.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../support/fake_core_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';
import '../support/tv.dart';

/// The check beside the bookmark: whether a film is watched, from the
/// library item, and the way to change it -- stremio-core's own
/// `MetaItemMarkAsWatched`. Films only.
void main() {
  const movieId = 'tt0063350';

  late FakeCoreClient core;

  /// The film fixture with its library item [watched] (`timesWatched`), or
  /// with none at all ([inLibrary] false): a film the library never saw.
  Map<String, dynamic> film({bool watched = false, bool inLibrary = true}) {
    final fixture = loadMetaDetailsFixture();
    if (!inLibrary) {
      fixture['libraryItem'] = null;
    } else if (watched) {
      ((fixture['libraryItem'] as Map<String, dynamic>)['state']
              as Map<String, dynamic>)['timesWatched'] =
          1;
    }
    return fixture;
  }

  Future<void> mount(
    WidgetTester tester,
    Map<String, dynamic> details, {
    DeviceProfile device = DeviceProfile.fallback,
    String type = 'movie',
    String id = movieId,
  }) async {
    if (device.isTv) {
      useScreen(tester, tvSize);
    } else {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    final prefs = AppPrefs(
      client: FakePrefsClient({'streamsSectioned': false}),
    );
    addTearDown(prefs.dispose);
    await prefs.load();
    core = FakeCoreClient(state: {CoreField.metaDetails: details});
    await tester.pumpWidget(
      DeviceScope(
        profile: device,
        child: CoreScope(
          client: core,
          child: PrefsScope(
            prefs: prefs,
            child: PlaybackScope(
              createEngine: FakePlaybackEngine.new,
              torrentStats: FakeTorrentStatsClient(),
              child: MaterialApp(
                theme: XtremioApp.themeFor(
                  isTv: device.isTv,
                  emphasis: FocusEmphasis.bold,
                ),
                builder: device.isTv ? TvMediaQuery.builder : null,
                home: MetaDetailsScreen(type: type, id: id),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  IconButton check(WidgetTester tester, String tooltip) => tester.widget(
    find.ancestor(
      of: find.byTooltip(tooltip),
      matching: find.byType(IconButton),
    ),
  );

  /// The last `MetaItemMarkAsWatched` sent, as `(id, is_watched)`.
  (String, bool)? marked() {
    for (final action in core.dispatched.reversed) {
      final json = action.toJson();
      final args = json['action']?['args'];
      if (args is Map && args['action'] == 'MetaItemMarkAsWatched') {
        expect(json['field'], 'ctx');
        final sent = args['args'] as Map;
        return (
          (sent['meta_item'] as Map)['id'] as String,
          sent['is_watched'] as bool,
        );
      }
    }
    return null;
  }

  testWidgets('unwatched: an outlined check that marks the film watched', (
    tester,
  ) async {
    await mount(tester, film());
    expect(check(tester, WatchedButton.markTooltip).isSelected, isFalse);
    expect(find.byTooltip(WatchedButton.watchedTooltip), findsNothing);
    await tester.tap(find.byTooltip(WatchedButton.markTooltip));
    await tester.pump();
    expect(marked(), (movieId, true));
  });

  testWidgets('watched: a filled check that clears it', (tester) async {
    await mount(tester, film(watched: true));
    expect(check(tester, WatchedButton.watchedTooltip).isSelected, isTrue);
    await tester.tap(find.byTooltip(WatchedButton.watchedTooltip));
    await tester.pump();
    expect(marked(), (movieId, false));

    // The engine's answer redraws it.
    core.setState(CoreField.metaDetails, film());
    await tester.pumpAndSettle();
    expect(check(tester, WatchedButton.markTooltip).isSelected, isFalse);
  });

  testWidgets('a film the library never saw is marked with the meta item, '
      'which makes the temporary item', (tester) async {
    await mount(tester, film(inLibrary: false));
    expect(check(tester, WatchedButton.markTooltip).isSelected, isFalse);
    await tester.tap(find.byTooltip(WatchedButton.markTooltip));
    await tester.pump();
    expect(marked(), (movieId, true));
  });

  testWidgets('a series shows no check', (tester) async {
    await mount(
      tester,
      loadSeriesEpisodeMetaDetailsFixture(),
      type: 'series',
      id: 'tt0903747',
    );
    expect(find.byTooltip(TvMetaHeader.addTooltip), findsOneWidget);
    expect(find.byTooltip(WatchedButton.markTooltip), findsNothing);
    expect(find.byTooltip(WatchedButton.watchedTooltip), findsNothing);
  });

  testWidgets('on a television the check is the stop between the bookmark '
      'and the faces, and keeps the remote across a toggle', (tester) async {
    await mount(tester, film(), device: tv);
    for (var i = 0; i < 8 && !focusIn<TvMetaHeader>(); i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    for (var i = 0; i < 3 && focusedTooltip() != TvMetaHeader.addTooltip; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focusedTooltip(), TvMetaHeader.addTooltip);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTooltip(), WatchedButton.markTooltip);

    await press(tester, LogicalKeyboardKey.select);
    expect(marked(), (movieId, true));
    core.setState(CoreField.metaDetails, film(watched: true));
    await tester.pumpAndSettle();
    expect(focusedTooltip(), WatchedButton.watchedTooltip);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTooltip(), FaceButtons.likeTooltip);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTooltip(), WatchedButton.watchedTooltip);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTooltip(), TvMetaHeader.addTooltip);
  });
}
