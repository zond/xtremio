import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/details_header.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/tv_meta_header.dart';
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
    Map<String, dynamic>? fixture,
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
    final core = FakeCoreClient(
      state: {CoreField.metaDetails: fixture ?? withTrailer()},
    );
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

  group('the title\'s own trailer', () {
    /// The first of the recorded title's trailers (Cinemeta lists two).
    final first = Uri.parse('https://www.youtube.com/watch?v=DIuI6T48Sj0');

    test('is the first trailer that is a YouTube video', () {
      final meta = MetaDetailsState.fromJson(loadMetaDetailsFixture()).meta!;
      expect(meta.trailerStreams, hasLength(2));
      expect(meta.trailerUrl, first);
      expect(const MetaItem({'id': 'x', 'type': 'movie'}).trailerUrl, isNull);
    });

    testWidgets('is a button under the description that opens YouTube', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final opener = await mount(
        tester,
        device: DeviceProfile.fallback,
        fixture: loadMetaDetailsFixture(),
      );

      final button = find.widgetWithText(OutlinedButton, TrailerButton.label);
      expect(button, findsOneWidget);
      final description = find.byType(ExpandableText);
      expect(
        tester.getTopLeft(button).dy,
        greaterThan(tester.getBottomLeft(description).dy),
        reason: 'below the words',
      );

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(opener.opened, [first]);
      expect(find.byType(PlayerScreen), findsNothing);
    });

    testWidgets('is not drawn for a title with none', (tester) async {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = loadMetaDetailsFixture();
      final meta =
          fixture['metaItems'][0]['content']['content'] as Map<String, dynamic>;
      meta['trailerStreams'] = <Object>[];
      await mount(tester, device: DeviceProfile.fallback, fixture: fixture);

      expect(find.text(TrailerButton.label), findsNothing);
    });

    testWidgets('on a television it is a stop under the plot, before the '
        'bookmark, and select opens YouTube', (tester) async {
      useScreen(tester, tvSize);
      final opener = await mount(
        tester,
        device: tv,
        fixture: loadMetaDetailsFixture(),
      );

      for (var i = 0; i < 12 && !focusIn<TvMetaHeader>(); i++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusIn<TvDescription>(), isTrue, reason: 'up lands on the plot');
      // The header's declared order, which Tab walks: the plot, then this.
      await press(tester, LogicalKeyboardKey.tab);
      expect(focusedLabel(tester), TrailerButton.label);
      expect(focusIn<TvMetaHeader>(), isTrue);
      await press(tester, LogicalKeyboardKey.select);

      expect(opener.opened, [first]);
      expect(find.byType(PlayerScreen), findsNothing);
    });

    testWidgets('on a television the D-pad reaches it: down from the plot, '
        'wearing the ring, and select opens YouTube', (tester) async {
      useScreen(tester, tvSize);
      final opener = await mount(
        tester,
        device: tv,
        fixture: loadMetaDetailsFixture(),
      );

      // A remote has no Tab: arrows and select only, from where the
      // screen put the remote.
      for (var i = 0; i < 12 && !focusIn<TvMetaHeader>(); i++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusIn<TvDescription>(), isTrue, reason: 'up lands on the plot');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), TrailerButton.label, reason: 'under it');
      expect(focusIn<TvMetaHeader>(), isTrue);
      expect(focusMarks(), contains(FocusMark.ring));

      // Up goes back to the plot, and down again past the trailer leaves
      // the header for the rung below, as it did before the trailer.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIn<TvDescription>(), isTrue, reason: 'back up to the plot');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), TrailerButton.label);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIn<TvMetaHeader>(), isFalse, reason: 'out of the header');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(
        focusedLabel(tester),
        TrailerButton.label,
        reason: 'the header remembers the stop it was left from',
      );

      await press(tester, LogicalKeyboardKey.select);
      expect(opener.opened, [first]);
      expect(find.byType(PlayerScreen), findsNothing);
    });

    testWidgets('on a television down from an unfolded plot puts the trailer '
        'on the screen', (tester) async {
      useScreen(tester, tvSize);
      // A plot long enough that, unfolded, it pushes the trailer under the
      // bottom edge of the screen.
      final fixture = loadMetaDetailsFixture();
      final meta =
          fixture['metaItems'][0]['content']['content'] as Map<String, dynamic>;
      meta['description'] = List.filled(40, meta['description']).join(' ');
      await mount(tester, device: tv, fixture: fixture);

      for (var i = 0; i < 12 && !focusIn<TvMetaHeader>(); i++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusIn<TvDescription>(), isTrue);
      await press(tester, LogicalKeyboardKey.select);
      for (var i = 0; i < 12 && !focusIn<OutlinedButton>(); i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedLabel(tester), TrailerButton.label);
      final button = find.widgetWithText(OutlinedButton, TrailerButton.label);
      // Its middle rather than its edge: the button is revealed at its
      // resting size, and the focus zoom then grows it a little past that.
      expect(
        tester.getCenter(button).dy,
        lessThanOrEqualTo(tvSize.height),
        reason: 'the remote is somewhere the viewer can see',
      );
    });

    testWidgets('on a television every stop in the header is reachable by '
        'the D-pad', (tester) async {
      useScreen(tester, tvSize);
      await mount(tester, device: tv, fixture: loadMetaDetailsFixture());

      final header = find.byType(TvMetaHeader);
      bool inHeader(FocusNode node) {
        final context = node.context;
        return context != null &&
            context.findAncestorWidgetOfExactType<TvMetaHeader>() != null;
      }

      final all = {
        for (final node in FocusManager.instance.rootScope.descendants)
          if (inHeader(node) &&
              node.canRequestFocus &&
              !node.skipTraversal &&
              node is! FocusScopeNode)
            node,
      };
      expect(header, findsOneWidget);
      expect(all, hasLength(3), reason: 'the plot, the trailer, the bookmark');

      for (var i = 0; i < 12 && !focusIn<TvMetaHeader>(); i++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      // Every stop one arrow press away from a stop already reached. Coming
      // back to a stop to try the next arrow is a jump, not a press: what a
      // press can reach from a stop does not depend on how it was reached.
      final reached = {FocusManager.instance.primaryFocus!};
      final pending = [...reached];
      while (pending.isNotEmpty) {
        final from = pending.removeLast();
        for (final key in [
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
        ]) {
          from.requestFocus();
          await tester.pumpAndSettle();
          await press(tester, key);
          final to = FocusManager.instance.primaryFocus;
          if (to != null && inHeader(to) && reached.add(to)) pending.add(to);
        }
      }
      expect(reached, all);
    });
  });
}
