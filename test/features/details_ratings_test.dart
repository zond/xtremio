import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/details_header.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/title_scores.dart';
import 'package:xtremio/features/details/tv_meta_header.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/ratings/xtremio_ratings.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/external_link.dart';

import '../support/fake_core_client.dart';
import '../support/fake_link_opener.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_ratings_provider.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';
import '../support/tv.dart';

/// The scores on the details header: the addon's IMDb rating at once, and
/// TMDB and Rotten Tomatoes' two meters when the server answers -- on a
/// phone as a row with the IMDb link kept, on a television as a line of
/// text the remote never stops on.
void main() {
  const movieId = 'tt0063350';
  const scores = TitleRatings(
    imdb: TitleScore(7.9, votes: 140000),
    tmdb: TitleScore(7.4, votes: 2500),
    tomatoes: TitleScore(96, votes: 80),
    popcorn: TitleScore(87),
  );

  /// The fixture's IMDb rating, from the addon.
  const addonImdb = '7.8';
  const tvLine = 'IMDb 7.8 · TMDB 7.4 · RT 96% · Popcorn 87%';

  late FakeRatingsProvider provider;
  late FakeLinkOpener opener;
  late AppPrefs prefs;

  Future<void> mount(
    WidgetTester tester, {
    required DeviceProfile device,
    Map<String, dynamic>? fixture,
    Map<String, dynamic> stored = const {},
    String type = 'movie',
  }) async {
    prefs = AppPrefs(
      client: FakePrefsClient({'streamsSectioned': false, ...stored}),
    );
    addTearDown(prefs.dispose);
    await prefs.load();
    opener = FakeLinkOpener();
    final core = FakeCoreClient(
      state: {CoreField.metaDetails: fixture ?? loadMetaDetailsFixture()},
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
              child: RatingsScope(
                provider: provider,
                child: PlaybackScope(
                  createEngine: FakePlaybackEngine.new,
                  torrentStats: FakeTorrentStatsClient(),
                  child: MaterialApp(
                    home: MetaDetailsScreen(type: type, id: movieId),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Finder inScores(String text) => find.descendant(
    of: find.byType(DetailsScores),
    matching: find.text(text),
  );

  setUp(() => provider = FakeRatingsProvider(scores));

  group('on a phone', () {
    testWidgets('IMDb stays the addon\'s link, and TMDB, RT and Popcorn '
        'follow it', (tester) async {
      usePhone(tester);
      await mount(tester, device: DeviceProfile.fallback);

      expect(provider.asked, ['movie/$movieId']);
      for (final (value, label) in [
        (addonImdb, 'IMDb'),
        ('7.4', 'TMDB'),
        ('96%', 'RT'),
        ('87%', 'Popcorn'),
      ]) {
        expect(inScores(value), findsOneWidget, reason: label);
        expect(inScores(label), findsOneWidget);
      }
      expect(
        tester.getCenter(inScores('Popcorn')).dy,
        moreOrLessEquals(tester.getCenter(inScores(addonImdb)).dy, epsilon: 2),
        reason: 'one row, the link hugging its own words',
      );
      expect(
        find.text('7.9'),
        findsNothing,
        reason: 'the addon\'s IMDb rating is not replaced a moment later',
      );
      expect(
        find.bySemanticsLabel('Rotten Tomatoes Tomatometer 96%'),
        findsOneWidget,
      );

      await tester.tap(find.text(addonImdb));
      await tester.pumpAndSettle();
      expect(opener.opened, [Uri.parse('https://imdb.com/title/$movieId')]);

      // The others open nothing.
      await tester.tap(find.text('96%'));
      await tester.pumpAndSettle();
      expect(opener.opened, hasLength(1));
    });

    testWidgets('shows the addon\'s IMDb rating while the server has not '
        'answered, and only that when it fails', (tester) async {
      usePhone(tester);
      final answer = Completer<TitleRatings>();
      provider.answer = answer;
      await mount(tester, device: DeviceProfile.fallback);

      expect(inScores(addonImdb), findsOneWidget);
      expect(inScores('TMDB'), findsNothing);
      expect(find.byType(ExpandableText), findsOneWidget, reason: 'the page');

      answer.completeError(const RatingsFailure('503'));
      await tester.pumpAndSettle();
      expect(inScores(addonImdb), findsOneWidget);
      expect(inScores('TMDB'), findsNothing);
      expect(inScores('RT'), findsNothing);
    });

    testWidgets('draws what this device remembers at once, before any '
        'answer', (tester) async {
      usePhone(tester);
      provider.answer = Completer<TitleRatings>();
      final remembered = TitleRatingsMemory.empty.remembering(
        type: 'movie',
        id: movieId,
        ratings: scores,
        // Old enough to be asked about again: the remembered scores are
        // what is on screen while that ask is out.
        at: DateTime.utc(2020),
      );
      await mount(
        tester,
        device: DeviceProfile.fallback,
        stored: {AppPrefs.titleRatingsKey: remembered.toJson()},
      );

      expect(provider.asked, ['movie/$movieId']);
      expect(inScores('7.4'), findsOneWidget);
      expect(inScores('96%'), findsOneWidget);
    });

    testWidgets('a title with no rating from the addon takes MDBList\'s, '
        'without a link', (tester) async {
      usePhone(tester);
      final fixture = loadMetaDetailsFixture();
      void strip(Object? node) {
        if (node is List) {
          node.forEach(strip);
          return;
        }
        if (node is! Map<String, dynamic>) return;
        final links = node['links'];
        if (links is List) {
          links.removeWhere(
            (link) => link is Map && link['category'] == 'imdb',
          );
        }
        node.values.forEach(strip);
      }

      strip(fixture);
      await mount(tester, device: DeviceProfile.fallback, fixture: fixture);

      expect(inScores('7.9'), findsOneWidget);
      expect(
        find.ancestor(of: inScores('7.9'), matching: find.byType(InkWell)),
        findsNothing,
      );
    });

    testWidgets('nothing is asked about a type the server does not answer '
        'for', (tester) async {
      usePhone(tester);
      await mount(tester, device: DeviceProfile.fallback, type: 'channel');
      expect(provider.asked, isEmpty);
    });
  });

  group('on a television', () {
    Finder header() => find.byType(TvMetaHeader);

    testWidgets('the scores are one line of text under the facts', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      await mount(tester, device: tv);

      final line = find.descendant(of: header(), matching: find.text(tvLine));
      expect(line, findsOneWidget);
      final text = tester.widget<Text>(line);
      expect(text.maxLines, 1);
      final facts = find.descendant(
        of: header(),
        matching: find.text('1968 · 96 min · Horror, Thriller'),
      );
      expect(
        tester.getTopLeft(line).dy,
        greaterThan(tester.getTopLeft(facts).dy),
      );
    });

    testWidgets('before an answer the line is the addon\'s IMDb rating '
        'alone', (tester) async {
      useScreen(tester, tvSize);
      provider.answer = Completer<TitleRatings>();
      await mount(tester, device: tv);

      expect(
        find.descendant(of: header(), matching: find.text('IMDb 7.8')),
        findsOneWidget,
      );
    });

    testWidgets('the remote never stops on a score, and every stop in the '
        'header is still reachable by the D-pad', (tester) async {
      useScreen(tester, tvSize);
      await mount(tester, device: tv);
      expect(
        find.descendant(of: header(), matching: find.text(tvLine)),
        findsOneWidget,
      );

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
      expect(
        all,
        hasLength(3),
        reason: 'the plot, the trailer, the bookmark -- no score',
      );

      for (var i = 0; i < 12 && !focusIn<TvMetaHeader>(); i++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusIn<TvDescription>(), isTrue, reason: 'up lands on the plot');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(tester), TrailerButton.label);

      // Every stop one arrow press away from a stop already reached, as in
      // `details_youtube_test.dart`; the scores line adds none.
      final reached = <FocusNode>{FocusManager.instance.primaryFocus!};
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
