import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/subtitle_groups.dart';
import 'package:xtremio/features/player/track_menus.dart';

import '../../support/fixtures.dart';
import '../../support/player_harness.dart';

/// Subtitles: the menu over embedded tracks and addon files, selection,
/// the session preference, styling, and the parameters the core needs to
/// ask the addons at all.
void main() {
  const spanishUrl = 'https://subs.example.org/tt0063350/spa.srt';
  const frenchUrl = 'https://subs.example.org/tt0063350/fre.vtt';

  Map<String, dynamic> subtitlesResponse(
    List<Map<String, dynamic>> items, {
    String base = 'https://subs.example.org/manifest.json',
  }) => {
    'request': {
      'base': base,
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
    // One row per language -- the stream carried the Spanish file too,
    // and it is the same file, so there is still one Spanish row.
    expect(find.text('Spanish'), findsOneWidget);
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

  /// What OpenSubtitles v3 really answers: many uploads per language, no
  /// labels, one file in a language nothing knows the name of. Installed
  /// in the anonymous profile, so the rows can name the addon.
  const openSubtitles = 'https://opensubtitles-v3.strem.io/manifest.json';
  String uploadUrl(String lang, int index) =>
      'https://subs5.strem.io/$lang/file/$index';

  PlayerHarness harnessWithManyUploads() {
    final harness = PlayerHarness();
    harness.fixture['subtitles'] = [
      subtitlesResponse(base: openSubtitles, [
        for (var i = 1; i <= 15; i++)
          {'id': 'en-$i', 'lang': 'eng', 'url': uploadUrl('en', i)},
        {'id': 'zz-1', 'lang': 'zzz', 'url': uploadUrl('zz', 1)},
      ]),
    ];
    return harness;
  }

  /// Opens the subtitle sheet and brings [text] into view.
  Future<void> openMenu(WidgetTester tester, [String? text]) async {
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    if (text != null) {
      await tester.ensureVisible(find.text(text));
      await tester.pumpAndSettle();
    }
  }

  /// The second line of the [ListTile] whose first line is [title].
  String subtitleOf(WidgetTester tester, String title) {
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
    );
    return (tile.subtitle! as Text).data!;
  }

  testWidgets('fifteen English uploads are one row, the rest one press away', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = harnessWithManyUploads();
    await harness.pump(tester);
    await openMenu(tester);

    // One row per language, not one per upload -- and the row says which
    // of the fifteen it would apply and who offered it.
    expect(find.text('English'), findsOneWidget);
    expect(subtitleOf(tester, 'English'), 'Option 1 · OpenSubtitles v3');

    // A code the name table does not know shows as itself rather than
    // being hidden, and it is the only file of its language.
    expect(find.text('zzz'), findsOneWidget);
    expect(subtitleOf(tester, 'zzz'), 'OpenSubtitles v3');
    expect(find.text('Option 1'), findsNothing, reason: 'nothing expanded');

    // The other fourteen are behind a row of their own.
    const more = '14 other English files';
    expect(find.text(more), findsOneWidget);
    await tester.ensureVisible(find.text(more));
    await tester.pumpAndSettle();
    await tester.tap(find.text(more));
    await tester.pumpAndSettle();
    expect(find.text('Hide other English files'), findsOneWidget);
    expect(find.text('Option 1'), findsOneWidget);

    // Picking one applies that specific file, not the group's default.
    await tester.scrollUntilVisible(find.text('Option 3'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Option 3'));
    await tester.pumpAndSettle();
    expect(harness.engine.externalSubtitles, [
      (Uri.parse(uploadUrl('en', 3)), 'English', 'eng'),
    ]);
  });

  testWidgets('the pick survives the list being regrouped', (tester) async {
    useWideViewport(tester);
    final harness = harnessWithManyUploads();
    await harness.pump(tester);
    await openMenu(tester);
    await tester.tap(find.text('14 other English files'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Option 5'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Option 5'));
    await tester.pumpAndSettle();
    expect(
      harness.engine.externalSubtitles.single.$1,
      Uri.parse(uploadUrl('en', 5)),
    );

    // A late addon answer rebuilds every group. The English row is still
    // the selected one, and it still names the upload that is playing.
    pokeState(harness);
    await pumpEvents(tester);
    await openMenu(tester, 'English');
    expect(subtitleOf(tester, 'English'), 'Option 5 · OpenSubtitles v3');
    final row = tester.widget<ListTile>(
      find.ancestor(of: find.text('English'), matching: find.byType(ListTile)),
    );
    expect(row.selected, isTrue);
  });

  testWidgets('embedded tracks come first and never merge with the addons\'', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = harnessWithManyUploads();
    await harness.pump(tester);
    harness.engine.emitTracks(embedded);
    await pumpEvents(tester);
    await openMenu(tester);

    // Two sections, the file's own first, said plainly enough that the
    // difference between them is obvious.
    final inFile = tester.getTopLeft(find.text('In this file')).dy;
    final fromAddons = tester.getTopLeft(find.text('From subtitle addons')).dy;
    expect(inFile, lessThan(fromAddons));
    expect(
      find.textContaining('nothing to download'),
      findsOneWidget,
      reason: 'why the embedded tracks are worth having first',
    );

    // Both sections have English in them and they stay two things: the
    // embedded track above the addons' label, the addons' group below --
    // never one merged English row.
    final english = find.text('English');
    expect(english, findsNWidgets(3), reason: 'track 3, 4\'s language, group');
    expect(tester.getTopLeft(english.first).dy, lessThan(fromAddons));
    expect(tester.getTopLeft(english.last).dy, greaterThan(fromAddons));
    expect(
      tester.getTopLeft(find.text('14 other English files')).dy,
      greaterThan(fromAddons),
    );
    expect(harness.engine.setSubtitleTrackIds, isEmpty);
    await tester.tap(english.first);
    await tester.pumpAndSettle();
    expect(harness.engine.setSubtitleTrackIds, [
      '3',
    ], reason: 'the embedded track, not a download');
    expect(harness.engine.externalSubtitles, isEmpty);
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

  /// A harness whose container is [videoFrameRate] and whose addon answers
  /// [items], with no session preference to auto-apply.
  PlayerHarness harnessRated(
    double? videoFrameRate,
    List<Map<String, dynamic>> items, {
    Map<String, dynamic>? preference,
  }) {
    final harness = PlayerHarness(
      configureEngine: (engine) => engine.frameRate = videoFrameRate,
    );
    harness.fixture['subtitlePreference'] = preference;
    harness.fixture['subtitles'] = [subtitlesResponse(items)];
    return harness;
  }

  /// One addon answer: a file of [lang] at [url], named [releaseGroup] in
  /// the menu, declaring [fpsMilli] as the rate it was cut for.
  Map<String, dynamic> upload(
    String id,
    String lang,
    String url,
    String releaseGroup, {
    int? fpsMilli,
  }) => {
    'id': id,
    'lang': lang,
    'url': url,
    'fpsMilli': ?fpsMilli,
    'releaseGroup': releaseGroup,
  };

  testWidgets('the menu offers every file, the ones that fit first', (
    tester,
  ) async {
    useWideViewport(tester);
    // A 23.976 fps container, which is what a film release is. The PAL
    // upload drifts four seconds a minute against it -- and that drift is
    // linear, so it is corrected rather than hidden.
    final harness = harnessRated(23.976, [
      upload(
        'en-1',
        'eng',
        'https://subs.example.org/en-25.srt',
        'PAL',
        fpsMilli: 25000,
      ),
      upload('en-2', 'eng', 'https://subs.example.org/en-silent.srt', 'SILENT'),
      upload(
        'en-3',
        'eng',
        'https://subs.example.org/en-23980.srt',
        'ROUNDED',
        fpsMilli: 23980,
      ),
    ]);
    await harness.pump(tester);
    final engine = harness.engine;
    // Nothing is asked before there is a video to ask about, and the rate
    // arrives with the media -- long before the menu can be opened.
    expect(engine.videoFrameRateCalls, 0);
    engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);
    expect(engine.videoFrameRateCalls, 1);
    // Read, not polled: the stats OSD is off and stays off.
    expect(engine.sampling, isFalse);

    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    // All three are on offer, and the row names the one that needs
    // nothing done to it -- an addon's `fpsMilli` is a claim about the
    // release it was cut for, and a claim can be wrong.
    expect(find.text('ROUNDED · subs.example.org'), findsOneWidget);
    await tester.tap(find.text('2 other English files'));
    await tester.pumpAndSettle();
    expect(find.text('ROUNDED'), findsOneWidget);
    expect(find.text('SILENT'), findsOneWidget);
    expect(find.text('PAL'), findsOneWidget);

    // A file that fits is played at its own timing.
    await tester.tap(find.text('ROUNDED'));
    await tester.pumpAndSettle();
    expect(engine.externalSubtitles.last.$1.path, endsWith('/en-23980.srt'));
    expect(engine.subtitleSpeed, 1);

    // The PAL file is offered too, and applying it re-times it: 25 fps
    // events against a 23.976 fps picture, so 1.0427.
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 other English files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PAL'));
    await tester.pumpAndSettle();
    expect(engine.externalSubtitles.last.$1.path, endsWith('/en-25.srt'));
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
  });

  testWidgets('a corrected row says so, in one word', (tester) async {
    useWideViewport(tester);
    // Not the rate: the number is noise to a viewer, and what a row has
    // to answer is whether this is the plain file or one we touched --
    // because a subtitle that still drifts sends them hunting for a
    // different upload, and they need to know what they are comparing.
    final harness = harnessRated(23.976, [
      upload(
        'en-1',
        'eng',
        'https://subs.example.org/en-25.srt',
        'PAL',
        fpsMilli: 25000,
      ),
      upload(
        'en-2',
        'eng',
        'https://subs.example.org/en-23980.srt',
        'ROUNDED',
        fpsMilli: 23980,
      ),
    ]);
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);

    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    // The row names the file that needs nothing, and says nothing extra.
    expect(find.text('ROUNDED · subs.example.org'), findsOneWidget);
    await tester.tap(find.text('1 other English file'));
    await tester.pumpAndSettle();
    expect(find.text('subs.example.org'), findsOneWidget);
    expect(find.text('subs.example.org · re-timed'), findsOneWidget);
    // The rate is not shown anywhere, on either row.
    expect(find.textContaining('25'), findsNothing);
    expect(find.textContaining('23.9'), findsNothing);

    // Applying it carries the word up onto the language row, which is
    // the row that is on screen once the sheet is closed and reopened.
    await tester.tap(find.text('PAL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    expect(find.text('PAL · subs.example.org · re-timed'), findsOneWidget);
  });

  testWidgets('a re-timed file is put back to 1.0 by every way out of it', (
    tester,
  ) async {
    useWideViewport(tester);
    // The failure this whole design is most likely to produce: a
    // multiplier belongs to the player, not to the file, so one left over
    // from the previous pick silently ruins a subtitle that was correct.
    final harness = harnessRated(23.976, [
      upload(
        'en-1',
        'eng',
        'https://subs.example.org/en-25.srt',
        'PAL',
        fpsMilli: 25000,
      ),
      upload(
        'pl-1',
        'pol',
        'https://subs.example.org/pl-23980.srt',
        'ROUNDED',
        fpsMilli: 23980,
      ),
    ]);
    await harness.pump(tester);
    final engine = harness.engine;
    // An embedded track of its own language, so its row is not one of the
    // two the addon files are listed under.
    engine.emitTracks(
      const PlaybackTracks(
        subtitle: [TrackInfo(id: '4', title: 'Commentary', language: 'ger')],
      ),
    );
    engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);

    Future<void> pick(String row) async {
      await tester.tap(find.byTooltip('Subtitles (S)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(row));
      await tester.pumpAndSettle();
    }

    await pick('English');
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));

    // Another file, which happens to need no correction at all.
    await pick('Polish');
    expect(engine.subtitleSpeed, 1);

    // An embedded track is part of the video and declares no rate of its
    // own, so it is played as it is.
    await pick('English');
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
    await pick('Commentary');
    expect(engine.setSubtitleTrackIds, ['4']);
    expect(engine.subtitleSpeed, 1);

    // And so is nothing at all: turning subtitles off leaves no
    // multiplier behind for whatever is picked next.
    await pick('English');
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
    await pick('Off');
    expect(engine.disableSubtitlesCalls, 1);
    expect(engine.subtitleSpeed, 1);
  });

  testWidgets('another video starts at its own timing', (tester) async {
    useWideViewport(tester);
    // The next episode opens on the same engine, and its container is not
    // the one the last file was corrected against.
    final harness = harnessRated(23.976, [
      upload(
        'en-1',
        'eng',
        'https://subs.example.org/en-25.srt',
        'PAL',
        fpsMilli: 25000,
      ),
    ]);
    await harness.pump(tester);
    final engine = harness.engine;
    engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));

    // The core resolves a different stream: same screen, same engine.
    final next = Map<String, dynamic>.from(harness.fixture);
    final stream = Map<String, dynamic>.from(next['stream'] as Map);
    final content = List<Object?>.from(stream['content'] as List);
    content[0] = {
      ...content[0]! as Map<String, dynamic>,
      'streaming_url': 'http://127.0.0.1:39661/next/0?',
    };
    next['stream'] = {...stream, 'content': content};
    harness.core.setState(CoreField.player, next);
    await pumpEvents(tester);
    expect(engine.opened.last.$1.path, '/next/0');
    expect(engine.subtitleSpeed, 1);
  });

  testWidgets('the session preference takes the file that fits, and re-times '
      'the one that does not', (tester) async {
    useWideViewport(tester);
    // The auto-pick is the one path that applies a subtitle without the
    // viewer looking. English was picked on the previous episode; the
    // addon answers a 25 fps upload first and a 23.980 one second, and
    // the container is 23.976 film, so the second is the better file.
    final harness = harnessRated(
      23.976,
      [
        upload(
          'en-1',
          'eng',
          'https://subs.example.org/en-25.srt',
          'PAL',
          fpsMilli: 25000,
        ),
        upload(
          'en-2',
          'eng',
          'https://subs.example.org/en-23980.srt',
          'ROUNDED',
          fpsMilli: 23980,
        ),
      ],
      preference: {'enabled': true, 'source': 'external', 'language': 'eng'},
    );
    await harness.pump(tester);
    final engine = harness.engine;
    expect(engine.externalSubtitles, isEmpty);
    engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);

    expect(engine.externalSubtitles, [
      (Uri.parse('https://subs.example.org/en-23980.srt'), 'English', 'eng'),
    ]);
    expect(engine.subtitleSpeed, 1);

    // And the menu agrees with what is playing: the row is selected.
    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(
            find.ancestor(
              of: find.text('English'),
              matching: find.byType(ListTile),
            ),
          )
          .selected,
      isTrue,
    );
  });

  testWidgets('the session preference re-times the only file there is', (
    tester,
  ) async {
    useWideViewport(tester);
    // Nothing in the language fits, so the pick nobody watched applies a
    // file that would drift four seconds a minute -- and corrects it.
    final harness = harnessRated(
      23.976,
      [
        upload(
          'en-1',
          'eng',
          'https://subs.example.org/en-25.srt',
          'PAL',
          fpsMilli: 25000,
        ),
      ],
      preference: {'enabled': true, 'source': 'external', 'language': 'eng'},
    );
    await harness.pump(tester);
    final engine = harness.engine;
    engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);
    expect(engine.externalSubtitles, [
      (Uri.parse('https://subs.example.org/en-25.srt'), 'English', 'eng'),
    ]);
    expect(engine.subtitleSpeed, closeTo(1.0427, 0.0001));
  });

  testWidgets('an auto-pick the engine refuses puts the multiplier back', (
    tester,
  ) async {
    useWideViewport(tester);
    // The one path that changes what is on screen and then changes it
    // back. mpv is already drawing a default-flagged embedded track that
    // is in step with the video; the preference asks for a 25 fps addon
    // file and mpv refuses it. Restoring the tracks without restoring the
    // multiplier leaves the refused file's 1.0427 on the subtitle that
    // stayed on screen -- four seconds a minute out, on a file nobody
    // asked us to touch.
    final harness = harnessRated(
      23.976,
      [
        upload(
          'en-1',
          'eng',
          'https://subs.example.org/en-25.srt',
          'PAL',
          fpsMilli: 25000,
        ),
      ],
      preference: {'enabled': true, 'source': 'external', 'language': 'eng'},
    );
    await harness.pump(tester);
    final engine = harness.engine..subtitleError = StateError('mpv: no');
    engine.emitTracks(
      const PlaybackTracks(
        subtitle: [TrackInfo(id: '3', title: 'English', language: 'eng')],
        activeSubtitleId: '3',
      ),
    );
    engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);

    // It tried, and it re-timed for the file it was about to add.
    expect(engine.externalSubtitles, hasLength(1));
    expect(engine.subtitleSpeeds, contains(closeTo(1.0427, 0.0001)));
    // The embedded track is what is drawn, and it is drawn as written.
    expect(engine.subtitleSpeed, 1);
  });

  testWidgets('a menu row stays a row, however long the addon name is', (
    tester,
  ) async {
    // `movieReleaseName` is addon text and arrives as long as it likes --
    // the real Breaking Bad answer has one of 122 characters -- and a
    // `ListTile` grows to fit whatever it is handed. On a phone that made
    // one alternative six lines tall, where `Option N` had been one.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SubtitleSource named(String url, String release) => SubtitleSource(
      SubtitleInfo(<String, dynamic>{
        'lang': 'eng',
        'url': url,
        'movieReleaseName': release,
      }),
      addonBase: 'https://opensubtitles-v3.strem.io/manifest.json',
    );
    final groups = groupSubtitlesByLanguage([
      named('https://subs/1.srt', 'Breaking Bad Season 1 Complete ${'x' * 90}'),
      named('https://subs/2.srt', 'Breaking Bad Season 1 Pilot ${'y' * 90}'),
    ], addonName: (_) => 'OpenSubtitles v3');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubtitleMenu(
            embedded: const [],
            groups: groups,
            activeId: null,
            loading: false,
            onOff: () {},
            onEmbedded: (_) {},
            onExternal: (_) {},
            onAdjustTiming: () {},
          ),
        ),
      ),
    );
    double heightOf(Finder text) => tester
        .getSize(find.ancestor(of: text, matching: find.byType(ListTile)))
        .height;
    // The language row, whose second line names the file it would apply.
    expect(heightOf(find.text('English')), lessThan(100));

    await tester.tap(find.text('1 other English file'));
    await tester.pumpAndSettle();
    expect(
      heightOf(find.textContaining('Breaking Bad Season 1 Pilot')),
      lessThan(100),
    );
  });

  testWidgets('an engine that cannot say the rate re-times nothing', (
    tester,
  ) async {
    useWideViewport(tester);
    // Every engine but libmpv, and libmpv before the first frame: with no
    // rate to compare against, the addons' order stands and no file is
    // touched. A guess here re-times a subtitle that was right.
    final harness = harnessRated(null, [
      upload(
        'en-1',
        'eng',
        'https://subs.example.org/en-25.srt',
        'PAL',
        fpsMilli: 25000,
      ),
      upload(
        'en-2',
        'eng',
        'https://subs.example.org/en-23980.srt',
        'ROUNDED',
        fpsMilli: 23980,
      ),
    ]);
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(minutes: 96));
    await pumpEvents(tester);
    expect(harness.engine.frameRate, isNull);

    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    // The row still names the addon's first answer, and both are there.
    expect(find.text('PAL · subs.example.org'), findsOneWidget);
    await tester.tap(find.text('1 other English file'));
    await tester.pumpAndSettle();
    expect(find.text('PAL'), findsOneWidget);
    expect(find.text('ROUNDED'), findsOneWidget);

    await tester.tap(find.text('PAL'));
    await tester.pumpAndSettle();
    expect(harness.engine.subtitleSpeed, 1);
  });
}
