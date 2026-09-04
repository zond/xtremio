import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/tv_backdrop.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

const String movieId = 'tt0063350';

void main() {
  /// The sources list flat, so this file's pumps do not depend on which
  /// resolution sections happen to be open.
  AppPrefs groupedPrefs() {
    final prefs = AppPrefs.inMemory();
    unawaited(prefs.setStreamsSectioned(false));
    return prefs;
  }

  /// The details screen with the television's own `MediaQuery` around it --
  /// the overscan band and text scale `XtremioApp` installs through
  /// `MaterialApp.builder` -- so the band is really there to bleed under.
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

  /// The movie fixture with its artwork replaced: `absent` drops a key.
  const Object absent = Object();
  Map<String, dynamic> movieWith({Object? background, Object? poster}) {
    final fixture = loadMetaDetailsFixture();
    final content =
        ((fixture['metaItems'] as List<dynamic>).first
                as Map<String, dynamic>)['content']['content']
            as Map<String, dynamic>;
    if (background != null) {
      content['background'] = background == absent ? null : background;
    }
    if (poster != null) content['poster'] = poster == absent ? null : poster;
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

  /// Where the topmost thing the screen draws starts: the app bar, which
  /// is the first content of the info column and so the corner that says
  /// whether the content is inside the band or bleeding under it.
  Offset contentCorner(WidgetTester tester) =>
      tester.getTopLeft(find.byType(AppBar));

  /// The corner the band leaves the content.
  Offset overscanCorner(Size screen) => Offset(
    screen.width * TvDensity.overscan,
    screen.height * TvDensity.overscan,
  );

  /// The URL of the topmost image the backdrop is drawing, null when it is
  /// drawing none and the ground is all there is.
  String? backdropUrl(WidgetTester tester) {
    final images = find.descendant(
      of: find.byType(TvBackdrop),
      matching: find.byType(Image),
    );
    if (images.evaluate().isEmpty) return null;
    final provider = tester.widget<Image>(images.first).image;
    return switch (provider) {
      ResizeImage(:final NetworkImage imageProvider) => imageProvider.url,
      NetworkImage(:final url) => url,
      _ => null,
    };
  }

  group('what the backdrop asks for', () {
    test('a metahub URL is asked for the size a full screen needs', () {
      expect(
        TvBackdrop.atSize(
          'https://images.metahub.space/poster/small/tt0063350/img',
          'medium',
        ),
        'https://images.metahub.space/poster/medium/tt0063350/img',
      );
      expect(
        TvBackdrop.atSize(
          'https://images.metahub.space/background/medium/tt0063350/img',
          'medium',
        ),
        'https://images.metahub.space/background/medium/tt0063350/img',
      );
    });

    test('any other addon keeps the URL it sent', () {
      const own = 'https://addon.example/art/small/tt1/img';
      expect(TvBackdrop.atSize(own, 'medium'), own);
      expect(
        TvBackdrop.atSize('https://images.metahub.space/logo/tt1', 'medium'),
        'https://images.metahub.space/logo/tt1',
      );
      expect(TvBackdrop.atSize(null, 'medium'), isNull);
    });
  });

  group('what the backdrop darkens', () {
    testWidgets('the picture, under a gradient -- never the text, and never '
        'a blur', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TvBackdrop(
            background: 'https://addon.example/backdrop.jpg',
            poster: null,
            child: Text('Night of the Living Dead'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final children = tester
          .widget<Stack>(
            find
                .descendant(
                  of: find.byType(TvBackdrop),
                  matching: find.byType(Stack),
                )
                .first,
          )
          .children;
      // The scrim is over the picture and the content is over the scrim,
      // so what is darkened is the frame and not the words on top of it.
      final picture = children.indexOf(children.whereType<Image>().single);
      final scrim = children.indexOf(children.whereType<DecoratedBox>().single);
      expect(scrim, greaterThan(picture));
      expect(children.last, isA<Text>());
      expect(
        (children[scrim] as DecoratedBox).decoration,
        const BoxDecoration(gradient: TvBackdrop.scrim),
      );
      // Dimmed text over a busy frame is the thing being avoided, and a
      // full-screen blur is what this GPU cannot afford.
      expect(find.byType(Opacity), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
    });
  });

  group('the backdrop on a television', () {
    testWidgets('is the background, at the size a full screen needs', (
      tester,
    ) async {
      await pump(tester, movieWith());

      expect(
        backdropUrl(tester),
        'https://images.metahub.space/background/medium/$movieId/img',
      );
    });

    testWidgets('falls back to the poster when there is no background', (
      tester,
    ) async {
      await pump(tester, movieWith(background: absent));

      // Cinemeta sends the *small* poster, which is what would otherwise be
      // stretched across the whole panel.
      expect(
        backdropUrl(tester),
        'https://images.metahub.space/poster/medium/$movieId/img',
      );
    });

    testWidgets('falls back to the poster when the background will not load, '
        'and to the brand ground when neither does', (tester) async {
      await pump(tester, movieWith());
      final images = find.descendant(
        of: find.byType(TvBackdrop),
        matching: find.byType(Image),
      );

      final background = tester.widget<Image>(images.first);
      final afterBackground = background.errorBuilder!(
        tester.element(images.first),
        'gone',
        null,
      );
      expect(afterBackground, isA<Image>());
      final poster = afterBackground as Image;
      expect(
        (poster.image as ResizeImage).imageProvider,
        isA<NetworkImage>().having(
          (image) => image.url,
          'url',
          'https://images.metahub.space/poster/medium/$movieId/img',
        ),
      );

      final afterPoster = poster.errorBuilder!(
        tester.element(images.first),
        'gone',
        null,
      );
      expect(afterPoster, isA<SizedBox>());
    });

    testWidgets('draws the brand ground and no image when there is no '
        'artwork at all', (tester) async {
      await pump(tester, movieWith(background: absent, poster: absent));

      expect(backdropUrl(tester), isNull);
      final ground = find.descendant(
        of: find.byType(TvBackdrop),
        matching: find.byType(ColoredBox),
      );
      expect(
        tester.widget<ColoredBox>(ground.first).color,
        Theme.of(tester.element(ground.first)).scaffoldBackgroundColor,
      );
      // A missing image may never disturb the layout: the content starts
      // in exactly the corner it starts in when the artwork loads.
      expect(contentCorner(tester), overscanCorner(tvSize));
    });

    testWidgets('bleeds under the overscan band the content keeps clear of', (
      tester,
    ) async {
      await pump(tester, movieWith());

      expect(tester.getRect(find.byType(TvBackdrop)), Offset.zero & tvSize);
      expect(contentCorner(tester), overscanCorner(tvSize));
    });

    testWidgets('is not drawn off a television, where the hero stays', (
      tester,
    ) async {
      await pump(tester, movieWith(), device: DeviceProfile.fallback);

      expect(find.byType(TvBackdrop), findsNothing);
      expect(find.byType(FlexibleSpaceBar), findsOneWidget);
    });
  });
}
