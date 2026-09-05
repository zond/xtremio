import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/tv_meta_header.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_density.dart';
import 'package:xtremio/widgets/focusable_tile.dart';
import 'package:xtremio/widgets/poster_tile.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

const String movieId = 'tt0063350';
const String movieName = 'Night of the Living Dead';

void main() {
  /// The sources list flat, so these pumps do not depend on which
  /// resolution sections happen to be open.
  AppPrefs groupedPrefs() {
    final prefs = AppPrefs.inMemory();
    unawaited(prefs.setStreamsSectioned(false));
    return prefs;
  }

  Widget harness(FakeCoreClient core, {DeviceProfile device = tv}) =>
      DeviceScope(
        profile: device,
        child: CoreScope(
          client: core,
          child: PrefsScope(
            prefs: groupedPrefs(),
            child: PlaybackScope(
              createEngine: FakePlaybackEngine.new,
              torrentStats: FakeTorrentStatsClient(),
              child: MaterialApp(
                builder: device.isTv ? TvMediaQuery.builder : null,
                home: const MetaDetailsScreen(type: 'movie', id: movieId),
              ),
            ),
          ),
        ),
      );

  /// The movie fixture with keys of its meta item replaced; a null value
  /// drops the key.
  Map<String, dynamic> movieWith(Map<String, Object?> fields) {
    final fixture = loadMetaDetailsFixture();
    final content =
        ((fixture['metaItems'] as List<dynamic>).first
                as Map<String, dynamic>)['content']['content']
            as Map<String, dynamic>;
    content.addAll(fields);
    return fixture;
  }

  Future<void> pump(
    WidgetTester tester,
    Map<String, dynamic> fixture, {
    DeviceProfile device = tv,
  }) async {
    useScreen(tester, tvSize);
    final core = FakeCoreClient(state: {CoreField.metaDetails: fixture});
    await tester.pumpWidget(harness(core, device: device));
    await tester.pumpAndSettle();
  }

  /// The image the header is leading with, null when it is leading with
  /// the name instead.
  Image? logoImage(WidgetTester tester) {
    final images = find.descendant(
      of: find.byType(TvMetaHeader),
      matching: find.byType(Image),
    );
    return images.evaluate().isEmpty
        ? null
        : tester.widget<Image>(images.first);
  }

  /// The `Text` the header draws [data] with.
  Text textOf(WidgetTester tester, String data) => tester.widget<Text>(
    find.descendant(of: find.byType(TvMetaHeader), matching: find.text(data)),
  );

  group('the one line of facts', () {
    test('is year, runtime, genres and rating, in that order', () {
      final meta = MetaDetailsState.fromJson(loadMetaDetailsFixture()).meta!;

      expect(
        TvMetaHeader.facts(meta),
        '1968 · 96 min · Horror, Thriller · IMDb 7.8',
      );
    });

    test('leaves out what the addon did not send rather than showing a '
        'gap for it', () {
      final bare = MetaItem({'id': 'tt1', 'type': 'movie', 'name': 'Bare'});

      expect(TvMetaHeader.facts(bare), '');
    });
  });

  group('the header on a television', () {
    testWidgets('leads with the logo, which carries the name for anything '
        'that cannot see it', (tester) async {
      await pump(tester, movieWith({}));

      final logo = logoImage(tester);
      expect(
        (logo?.image as NetworkImage?)?.url,
        'https://images.metahub.space/logo/medium/$movieId/img',
      );
      expect(logo?.semanticLabel, movieName);
    });

    testWidgets('leads with the name when the addon sent no logo', (
      tester,
    ) async {
      await pump(tester, movieWith({'logo': null}));

      expect(logoImage(tester), isNull);
      expect(
        find.descendant(
          of: find.byType(TvMetaHeader),
          matching: find.text(movieName),
        ),
        findsOneWidget,
      );
    });

    testWidgets('falls back to the name when the logo will not load', (
      tester,
    ) async {
      // Nothing fetches in a test, so what the header settles on is the
      // fallback itself.
      await pump(tester, movieWith({}));

      expect(logoImage(tester), isNotNull);
      expect(
        find.descendant(
          of: find.byType(TvMetaHeader),
          matching: find.text(movieName),
        ),
        findsOneWidget,
      );
    });

    testWidgets('and the name it falls back to keeps the logo\'s height, so '
        'nothing below it moves', (tester) async {
      // An `Image.network` given a height alone occupies exactly that from
      // its first frame, before a byte of it has arrived. A logo that 404s
      // seconds later replaces that box with the name, and if the name is
      // shorter the header, the pills, the episodes and both rows of
      // sources all jump up under a focus ring the viewer is using.
      await pump(tester, movieWith({}));

      final header = tester.getTopLeft(find.byType(TvMetaHeader)).dy;
      final facts = tester
          .getTopLeft(
            find.descendant(
              of: find.byType(TvMetaHeader),
              matching: find.text(
                '1968 · 96 min · Horror, Thriller · IMDb 7.8',
              ),
            ),
          )
          .dy;
      expect(facts - header, greaterThanOrEqualTo(TvMetaHeader.logoHeight));

      // And a title that ships no logo at all is drawn the same way, so
      // the header is one height whatever the addon sent.
      await pump(tester, movieWith({'logo': null}));
      final bare =
          tester
              .getTopLeft(
                find.descendant(
                  of: find.byType(TvMetaHeader),
                  matching: find.text(
                    '1968 · 96 min · Horror, Thriller · IMDb 7.8',
                  ),
                ),
              )
              .dy -
          tester.getTopLeft(find.byType(TvMetaHeader)).dy;
      expect(bare, facts - header);
    });

    testWidgets('says the facts once, on one line', (tester) async {
      await pump(tester, movieWith({}));

      final facts = textOf(
        tester,
        '1968 · 96 min · Horror, Thriller · IMDb 7.8',
      );
      expect(facts.maxLines, 1);
      expect(facts.overflow, TextOverflow.ellipsis);
    });

    testWidgets('clips the description to a couple of lines, with no way to '
        'unfold it', (tester) async {
      await pump(tester, movieWith({}));

      final meta = MetaDetailsState.fromJson(loadMetaDetailsFixture()).meta!;
      final description = textOf(tester, meta.description!);
      expect(description.maxLines, TvMetaHeader.descriptionLines);
      expect(description.overflow, TextOverflow.ellipsis);
      expect(find.text('More'), findsNothing);
    });

    testWidgets('drops the poster: the artwork is already the backdrop', (
      tester,
    ) async {
      await pump(tester, movieWith({}));

      expect(find.byType(PosterImage), findsNothing);
    });

    testWidgets('keeps the bookmark, which the remote has to reach', (
      tester,
    ) async {
      await pump(tester, movieWith({}));

      expect(
        find.descendant(
          of: find.byType(TvMetaHeader),
          matching: find.byTooltip(TvMetaHeader.addTooltip),
        ),
        findsOneWidget,
      );
    });

    testWidgets('and the bookmark wears the ring when the remote is on it', (
      tester,
    ) async {
      // Material gives a focused icon button a circular tint of about a
      // tenth, which over a darkened backdrop on somebody else's panel is
      // the one cue a bright room takes away. Every other focusable thing
      // on a television wears the two-stroke ring; a control the remote
      // can land on and nobody can find is worse than one that is not
      // there.
      await pump(tester, movieWith({}));
      for (
        var i = 0;
        i < 8 && focusedTooltip() != TvMetaHeader.addTooltip;
        i++
      ) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusedTooltip(), TvMetaHeader.addTooltip);

      final rings = tester.widgetList<FocusRing>(
        find.descendant(
          of: find.byType(TvMetaHeader),
          matching: find.byType(FocusRing),
        ),
      );
      expect(rings.where((ring) => ring.focused), hasLength(1));
    });
  });

  group('the header off a television', () {
    testWidgets('is the one it has always been: the poster, the genre chips '
        'and the description that unfolds', (tester) async {
      await pump(tester, movieWith({}), device: DeviceProfile.fallback);

      expect(find.byType(TvMetaHeader), findsNothing);
      expect(find.byType(PosterImage), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Horror'), findsOneWidget);
      expect(find.text('More'), findsOneWidget);
    });
  });
}
