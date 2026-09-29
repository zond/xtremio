import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/tv_source_row.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/external_link.dart';

import '../support/fake_core_client.dart';
import '../support/fake_link_opener.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';
import '../support/stream_groups.dart';
import '../support/tv.dart';

/// A YouTube stream -- a trailer addon's, a channel's video -- opens in the
/// YouTube app rather than the player: this app's server has no YouTube
/// resolver, so the player could only fail on it.
void main() {
  const movieId = 'tt0063350';
  const trailers = 'https://trailers.example/manifest.json';
  const ytId = 'dQw4w9WgXcQ';
  final youtube = Uri.parse('https://www.youtube.com/watch?v=$ytId');

  test('a YouTube stream is the address YouTube opens, and no other is', () {
    expect(const StreamInfo({'ytId': ytId}).youtubeUrl, youtube);
    expect(const StreamInfo({'ytId': ''}).youtubeUrl, isNull);
    expect(
      const StreamInfo({'url': 'https://example.org/a.mp4'}).youtubeUrl,
      isNull,
    );
  });

  Map<String, dynamic> withTrailer() {
    final fixture = loadMetaDetailsFixture();
    fixture['streams'] = [
      readyGroup(trailers, [
        {'ytId': ytId, 'name': 'Movie Trailers', 'title': 'Official trailer'},
      ]),
    ];
    return fixture;
  }

  Future<FakeLinkOpener> mount(
    WidgetTester tester, {
    required DeviceProfile device,
  }) async {
    final prefs = AppPrefs(
      client: FakePrefsClient({
        'streamsSectioned': false,
        'openStreamAddons': [trailers],
      }),
    );
    addTearDown(prefs.dispose);
    await prefs.load();
    final opener = FakeLinkOpener();
    final core = FakeCoreClient(state: {CoreField.metaDetails: withTrailer()});
    await tester.pumpWidget(
      DeviceScope(
        profile: device,
        child: CoreScope(
          client: core,
          child: ExternalLinkScope(
            opener: opener,
            child: PrefsScope(
              prefs: prefs,
              child: PlaybackScope(
                createEngine: FakePlaybackEngine.new,
                torrentStats: FakeTorrentStatsClient(),
                child: const MaterialApp(
                  home: MetaDetailsScreen(type: 'movie', id: movieId),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return opener;
  }

  testWidgets('a press on a trailer opens YouTube, not the player', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final opener = await mount(tester, device: DeviceProfile.fallback);

    final row = find.widgetWithText(ListTile, 'Official trailer');
    await tester.ensureVisible(row);
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.open_in_new)),
      findsOneWidget,
      reason: 'the row says it leaves the app',
    );
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(opener.opened, [youtube]);
    expect(find.byType(PlayerScreen), findsNothing);
  });

  testWidgets('on a television, select on the trailer\'s card opens YouTube', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final opener = await mount(tester, device: tv);

    final card = find.byType(TvSourceCard);
    for (var i = 0; i < 12 && !focusIn<TvSourceCard>(); i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(card, findsWidgets);
    expect(focusIn<TvSourceCard>(), isTrue, reason: 'the remote reached it');
    await press(tester, LogicalKeyboardKey.select);

    expect(opener.opened, [youtube]);
    expect(find.byType(PlayerScreen), findsNothing);
  });
}
