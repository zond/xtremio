import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/track_menus.dart';

import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// Subtitles: the menu over embedded tracks and addon files, selection,
/// the session preference, styling, and the parameters the core needs to
/// ask the addons at all.
void main() {
  const spanishUrl = 'https://subs.example.org/tt0063350/spa.srt';
  const frenchUrl = 'https://subs.example.org/tt0063350/fre.vtt';

  Map<String, dynamic> subtitlesResponse(List<Map<String, dynamic>> items) => {
    'request': {
      'base': 'https://subs.example.org/manifest.json',
      'path': {
        'resource': 'subtitles',
        'type': 'movie',
        'id': 'tt0063350',
        'extra': <Object>[],
      },
    },
    'content': {'type': 'Ready', 'content': items},
  };

  const loadingResponse = {
    'request': {
      'base': 'https://slow.example.org/manifest.json',
      'path': {
        'resource': 'subtitles',
        'type': 'movie',
        'id': 'tt0063350',
        'extra': <Object>[],
      },
    },
    'content': {'type': 'Loading'},
  };

  /// The recorded torrent plus two addon subtitle files (one of them also
  /// attached to the stream itself) and an addon still loading.
  PlayerHarness harnessWithSubtitles({
    Map<String, dynamic>? preference,
    bool loading = false,
  }) {
    final harness = PlayerHarness();
    harness.fixture['subtitles'] = [
      subtitlesResponse([
        {
          'id': 'spa-1',
          'lang': 'spa',
          'url': spanishUrl,
          'label': 'Español (forced)',
        },
        {'id': 'fre-1', 'lang': 'fre', 'url': frenchUrl},
      ]),
      if (loading) loadingResponse,
    ];
    (harness.selected['stream'] as Map<String, dynamic>)['subtitles'] = [
      {'id': 'dup', 'lang': 'spa', 'url': spanishUrl},
    ];
    harness.fixture['subtitlePreference'] = preference;
    return harness;
  }

  /// A `player` state change that alters nothing (a fresh copy, so the
  /// notifier does see a new value).
  void pokeState(PlayerHarness harness) => harness.core.setState(
    CoreField.player,
    Map<String, dynamic>.from(harness.fixture),
  );

  const embedded = PlaybackTracks(
    subtitle: [
      TrackInfo(id: '3', language: 'eng'),
      TrackInfo(id: '4', title: 'Commentary', language: 'eng'),
    ],
  );

  testWidgets('lists off, embedded tracks and addon files; selects them', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = harnessWithSubtitles();
    await harness.pump(tester);
    final engine = harness.engine;
    engine.emitTracks(embedded);
    await pumpEvents(tester);
    expect(find.byIcon(Icons.subtitles_off), findsOneWidget);

    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    expect(find.byType(SubtitleMenu), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('English'), findsNWidgets(2)); // track 3, and 4's language
    expect(find.text('Commentary'), findsOneWidget);
    expect(find.text('Español (forced)'), findsOneWidget); // deduplicated
    expect(find.text('French'), findsOneWidget);
    expect(find.text('subs.example.org'), findsNWidgets(2));
    expect(find.text('Looking for subtitles…'), findsNothing);

    // An addon file: loaded from its URL, remembered as the preference.
    // (The sheet scrolls; the last rows start below the fold.)
    await tester.ensureVisible(find.text('French'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('French'));
    await tester.pumpAndSettle();
    expect(find.byType(SubtitleMenu), findsNothing);
    expect(engine.externalSubtitles, [(Uri.parse(frenchUrl), 'French', 'fre')]);
    expect(harness.lastPlayerArgs('SubtitlePreferenceChanged'), {
      'preference': {'enabled': true, 'source': 'external', 'language': 'fre'},
    });
    expect(find.byIcon(Icons.subtitles), findsOneWidget);

    // Reopening shows it selected.
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('French'));
    await tester.pumpAndSettle();
    final french = tester.widget<ListTile>(
      find.ancestor(of: find.text('French'), matching: find.byType(ListTile)),
    );
    expect(french.selected, isTrue);

    // An embedded track.
    await tester.tap(find.text('Commentary'));
    await tester.pumpAndSettle();
    expect(engine.setSubtitleTrackIds, ['4']);
    expect(harness.lastPlayerArgs('SubtitlePreferenceChanged'), {
      'preference': {'enabled': true, 'source': 'embedded', 'language': 'eng'},
    });

    // Off.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pumpAndSettle();
    expect(find.byType(SubtitleMenu), findsOneWidget);
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(engine.disableSubtitlesCalls, 1);
    expect(harness.lastPlayerArgs('SubtitlePreferenceChanged'), {
      'preference': {'enabled': false},
    });
    expect(find.byIcon(Icons.subtitles_off), findsOneWidget);
  });

  testWidgets('shows a progress row while an addon is still answering', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = harnessWithSubtitles(loading: true);
    await harness.pump(tester);
    await tester.tap(find.byTooltip('Subtitles (S)'));
    // The spinner never settles; pump the sheet's animation by hand.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Looking for subtitles…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('French'), findsOneWidget);

    // The slow addon answers: the row goes away while the menu is open.
    harness.core.setState(CoreField.player, {
      ...harness.fixture,
      'subtitles': [(harness.fixture['subtitles'] as List<dynamic>).first],
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('Looking for subtitles…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('applies the session preference once the media is loaded', (
    tester,
  ) async {
    useWideViewport(tester);
    // External French picked earlier in this Player session. Nothing is
    // added while mpv is still between files: the pick waits for the
    // engine to report the media in (a duration, or playing).
    var harness = harnessWithSubtitles(
      preference: {'enabled': true, 'source': 'external', 'language': 'fre'},
    );
    await harness.pump(tester);
    expect(harness.engine.externalSubtitles, isEmpty);
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    expect(harness.engine.externalSubtitles.single.$1, Uri.parse(frenchUrl));
    expect(
      harness.playerActions(),
      isNot(contains('SubtitlePreferenceChanged')),
    );
    // Once applied, later state changes do not re-add it.
    pokeState(harness);
    await pumpEvents(tester);
    expect(harness.engine.externalSubtitles, hasLength(1));

    // Embedded English: waits for the tracks, then picks the first match.
    harness = harnessWithSubtitles(
      preference: {'enabled': true, 'source': 'embedded', 'language': 'en'},
    );
    await harness.pump(tester);
    harness.engine.emitTracks(embedded);
    await pumpEvents(tester);
    expect(harness.engine.setSubtitleTrackIds, isEmpty);
    harness.engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);
    expect(harness.engine.setSubtitleTrackIds, ['3']);
    expect(harness.engine.externalSubtitles, isEmpty);

    // Off stays off, whatever the container would default to.
    harness = harnessWithSubtitles(preference: {'enabled': false});
    await harness.pump(tester);
    expect(harness.engine.disableSubtitlesCalls, 0);
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    expect(harness.engine.disableSubtitlesCalls, 1);
  });

  testWidgets('a rejected auto-pick is retried, not counted as applied', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = harnessWithSubtitles(
      preference: {'enabled': true, 'source': 'external', 'language': 'fre'},
    );
    await harness.pump(tester);
    final engine = harness.engine..subtitleError = StateError('mpv: no');
    engine.emitPlaying(true);
    await pumpEvents(tester);
    expect(engine.externalSubtitles, hasLength(1));
    expect(
      find.byIcon(Icons.subtitles_off),
      findsOneWidget,
      reason: 'nothing shows as selected',
    );

    // Still not applied: the next state change tries again.
    pokeState(harness);
    await pumpEvents(tester);
    expect(engine.externalSubtitles, hasLength(2));

    // Accepted now: done, no further attempts.
    engine.subtitleError = null;
    pokeState(harness);
    await pumpEvents(tester);
    expect(engine.externalSubtitles, hasLength(3));
    expect(find.byIcon(Icons.subtitles), findsOneWidget);
    pokeState(harness);
    await pumpEvents(tester);
    expect(engine.externalSubtitles, hasLength(3));
  });

  testWidgets('tells the core the filename once the media is open', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = PlayerHarness();
    (harness.selected['stream'] as Map<String, dynamic>)['behaviorHints'] = {
      'filename': 'Night.of.the.Living.Dead.1968.1080p.mkv',
    };
    await harness.pump(tester);
    expect(harness.playerActions(), ['VideoParamsChanged']);
    expect(harness.lastPlayerArgs('VideoParamsChanged'), {
      'videoParams': {
        'hash': null,
        'size': null,
        'filename': 'Night.of.the.Living.Dead.1968.1080p.mkv',
      },
    });
  });

  testWidgets('sends no filename rather than a stand-in', (tester) async {
    useWideViewport(tester);
    // The recorded torrent: no `behaviorHints.filename` anywhere, a
    // streaming URL ending in the file index, and a quality-label name.
    final harness = PlayerHarness();
    expect(harness.selected['stream']['name'], isNotNull);
    await harness.pump(tester);
    expect(harness.lastPlayerArgs('VideoParamsChanged'), {
      'videoParams': {'hash': null, 'size': null, 'filename': null},
    });
  });

  testWidgets('settings change the speed and write the subtitle style to '
      'the profile', (tester) async {
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    final engine = harness.engine;
    // The anonymous profile's defaults: 100 %, white, no background box.
    expect(engine.subtitleStyle, const SubtitleStyle());

    await tester.tap(find.byTooltip('Playback settings'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerSettingsSheet), findsOneWidget);
    await tester.tap(find.text('1.5×'));
    await tester.pump();
    expect(engine.rates, [1.5]);

    // A size pick is an UpdateSettings with the whole map and that one key
    // changed; the rendered style waits for the engine to report it.
    final before = harness.settings.json;
    await tester.tap(find.text('150 %'));
    await tester.pump();
    expect(harness.settingsUpdates(), [
      {...before, 'subtitlesSize': 150},
    ]);
    expect(engine.subtitleStyle, const SubtitleStyle());

    final ctx = loadCtxLoggedOutFixture();
    ctx['profile']['settings'] = {
      ...before,
      'subtitlesSize': 150,
      'subtitlesTextColor': '#FFEB3BFF',
      'subtitlesBackgroundColor': '#000000FF',
    };
    harness.core.setState(CoreField.ctx, ctx);
    await tester.pumpAndSettle();
    expect(
      engine.subtitleStyle,
      const SubtitleStyle(
        fontSize: 48,
        color: Color(0xFFFFEB3B),
        backgroundColor: Color(0xFF000000),
      ),
    );
    ChoiceChip chip(String label) =>
        tester.widget(find.widgetWithText(ChoiceChip, label));
    expect(chip('150 %').selected, isTrue);
    expect(chip('Yellow').selected, isTrue);
    expect(chip('Black').selected, isTrue);

    await tester.tap(find.text('Translucent'));
    await tester.pump();
    expect(harness.settingsUpdates().last, {
      ...ctx['profile']['settings'] as Map<String, dynamic>,
      'subtitlesBackgroundColor': '#000000AA',
    });
  });

  testWidgets('two chips in a row: the second write carries the first', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    await tester.tap(find.byTooltip('Playback settings'));
    await tester.pumpAndSettle();

    // Nothing from the engine between the two taps.
    final before = harness.settings.json;
    await tester.tap(find.text('150 %'));
    await tester.pump();
    await tester.tap(find.text('Yellow'));
    await tester.pump();
    expect(harness.settingsUpdates(), [
      {...before, 'subtitlesSize': 150},
      {...before, 'subtitlesSize': 150, 'subtitlesTextColor': '#FFEB3BFF'},
    ]);
    ChoiceChip chip(String label) =>
        tester.widget(find.widgetWithText(ChoiceChip, label));
    expect(chip('150 %').selected, isTrue);
    expect(chip('Yellow').selected, isTrue);

    // The next `ctx` pull is the authority again.
    harness.core.setState(CoreField.ctx, loadCtxLoggedOutFixture());
    await tester.pumpAndSettle();
    expect(chip('100 %').selected, isTrue);
    expect(chip('White').selected, isTrue);
  });

  testWidgets('a colour outside the palette shows as Custom', (tester) async {
    useWideViewport(tester);
    final ctx = loadCtxLoggedOutFixture();
    ctx['profile']['settings']['subtitlesTextColor'] = '#FF00FFFF';
    final harness = PlayerHarness(ctx: ctx);
    await harness.pump(tester);
    expect(harness.engine.subtitleStyle?.color, const Color(0xFFFF00FF));

    await tester.tap(find.byTooltip('Playback settings'));
    await tester.pumpAndSettle();
    final custom = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Custom (#FF00FFFF)'),
    );
    expect(custom.selected, isTrue);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'White'))
          .selected,
      isFalse,
    );
  });

  testWidgets('the style chips are disabled until the settings are known', (
    tester,
  ) async {
    useWideViewport(tester);
    // A `ctx` without a profile: the settings map is empty, and a partial
    // UpdateSettings would be rejected by the engine.
    final harness = PlayerHarness(ctx: {});
    await harness.pump(tester);
    expect(harness.engine.subtitleStyle, const SubtitleStyle());

    await tester.tap(find.byTooltip('Playback settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('150 %'));
    await tester.tap(find.text('Yellow'));
    await tester.pump();
    expect(harness.settingsUpdates(), isEmpty);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '150 %'))
          .onSelected,
      isNull,
    );
    // Speed is local and still works.
    await tester.tap(find.text('1.5×'));
    await tester.pump();
    expect(harness.engine.rates, [1.5]);
  });
}
