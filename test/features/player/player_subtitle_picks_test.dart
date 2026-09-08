import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_tracks.dart';

import '../../support/fake_prefs_client.dart';
import '../../support/player_harness.dart';

/// The next episode comes up the way the last one was left.
///
/// The engine's session preference is cleared when the player is
/// unloaded, so on a fresh start what this show was last watched with is
/// the only thing that knows anything -- the language, and the release
/// group of the file that was picked when the addon named one. What is
/// remembered is *only ever* written by a pick made by hand, and it never
/// invents a language this episode does not offer.
void main() {
  /// The meta item the recorded fixture is a stream for -- what
  /// `metaRequest.path.id` holds, which is what a pick is keyed on.
  const series = 'tt0063350';

  const fgtUrl = 'https://subs.example.org/en-fgt.srt';
  const plainUrl = 'https://subs.example.org/en-plain.srt';
  const swedishUrl = 'https://subs.example.org/sv-fgt.srt';

  Map<String, dynamic> upload(
    String id,
    String lang,
    String url, {
    String? releaseGroup,
  }) => {'id': id, 'lang': lang, 'url': url, 'releaseGroup': ?releaseGroup};

  /// The addon answering with [items] and no session preference at all --
  /// which is what every fresh start looks like, since the core clears
  /// the preference on `Unload`.
  PlayerHarness harnessWith(
    List<Map<String, dynamic>> items, {
    AppPrefs? prefs,
    Map<String, dynamic>? preference,
  }) {
    final harness = PlayerHarness(prefs: prefs);
    harness.fixture['subtitlePreference'] = preference;
    harness.fixture['subtitles'] = [
      {
        'request': {
          'base': 'https://subs.example.org/manifest.json',
          'path': {
            'resource': 'subtitles',
            'type': 'movie',
            'id': series,
            'extra': <Object>[],
          },
        },
        'content': {'type': 'Ready', 'content': items},
      },
    ];
    return harness;
  }

  /// The player with the media loaded, which is when the auto-pick runs.
  Future<PlayerHarness> playing(
    WidgetTester tester,
    PlayerHarness harness,
  ) async {
    await harness.pump(tester);
    harness.engine.emitDuration(const Duration(minutes: 96));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    return harness;
  }

  /// The player as above, with one English track inside the video --
  /// which is what a remembered row saying `embedded` has to find.
  Future<PlayerHarness> playingWithTrack(
    WidgetTester tester,
    PlayerHarness harness,
  ) async {
    await harness.pump(tester);
    harness.engine.emitTracks(
      const PlaybackTracks(
        subtitle: [TrackInfo(id: '3', language: 'eng')],
      ),
    );
    harness.engine.emitDuration(const Duration(minutes: 96));
    harness.engine.emitPlaying(true);
    await pumpEvents(tester);
    return harness;
  }

  /// Preferences holding one remembered row for this show.
  AppPrefs remembering(Map<String, Object?> show) => AppPrefs(
    client: FakePrefsClient({
      'subtitlePicks': {
        'shows': [
          {'series': series, ...show},
        ],
        'languages': {'English': 9},
      },
    }),
  );

  /// The two English uploads, the second of them from the group that is
  /// remembered -- so the pick is only right if the group was read.
  List<Map<String, dynamic>> twoEnglish() => [
    upload('en-1', 'eng', plainUrl, releaseGroup: 'PLAIN'),
    upload('en-2', 'eng', fgtUrl, releaseGroup: 'FGT'),
  ];

  testWidgets('a show watched before comes up in its language, from the '
      'group it was watched with', (tester) async {
    useWideViewport(tester);
    final prefs = remembering({'language': 'English', 'releaseGroup': 'fgt'});
    await prefs.load();

    final harness = await playing(
      tester,
      harnessWith(twoEnglish(), prefs: prefs),
    );

    // The addon answered the other upload first, and with no session
    // preference nothing but the memory could have chosen this one. The
    // group is stored lower-cased, and the addon spells it in capitals.
    expect(harness.engine.externalSubtitles, [
      (Uri.parse(fgtUrl), 'English', 'eng'),
    ]);
    // And applied exactly as it stands: remembering where a file came
    // from is not a claim about its timing.
    expect(harness.engine.subtitleSpeed, 1);
    expect(harness.engine.subtitleDelay, 0);
  });

  testWidgets('a show never watched is left alone', (tester) async {
    useWideViewport(tester);
    // English has been picked nine times on other shows, which is what
    // pins it in the menu -- and is still not a reason to put subtitles
    // on a programme nothing is known about. It might be one that needs
    // none.
    final prefs = AppPrefs(
      client: FakePrefsClient({
        'subtitlePicks': {
          'shows': [
            {'series': 'tt0944947', 'language': 'English'},
          ],
          'languages': {'English': 9},
        },
      }),
    );
    await prefs.load();

    final harness = await playing(
      tester,
      harnessWith(twoEnglish(), prefs: prefs),
    );

    expect(harness.engine.externalSubtitles, isEmpty);
    expect(harness.engine.disableSubtitlesCalls, 0);
  });

  testWidgets('an episode that answers without the remembered language '
      'plays none', (tester) async {
    useWideViewport(tester);
    final prefs = remembering({'language': 'Swedish', 'releaseGroup': 'fgt'});
    await prefs.load();

    final harness = await playing(
      tester,
      harnessWith(twoEnglish(), prefs: prefs),
    );

    // No Swedish here. Falling back to the language this viewer usually
    // picks would be the memory answering a question nobody asked: this
    // show is watched in Swedish, and today there is none.
    expect(harness.engine.externalSubtitles, isEmpty);
    // And the row stays: next episode may answer differently.
    expect(prefs.subtitlePicks.forSeries(series)!.language, 'Swedish');
  });

  testWidgets('an episode without the remembered group takes the head of '
      'the language', (tester) async {
    useWideViewport(tester);
    final prefs = remembering({'language': 'English', 'releaseGroup': 'fgt'});
    await prefs.load();

    // A season from another release family, and files that name no group
    // at all -- the ordinary case, since six entries in ten carry none.
    final harness = await playing(
      tester,
      harnessWith([
        upload('en-1', 'eng', plainUrl),
        upload('en-2', 'eng', fgtUrl, releaseGroup: 'MEDIEVAL'),
      ], prefs: prefs),
    );

    // The group is a preference among the files of the language, never a
    // condition on the language.
    expect(harness.engine.externalSubtitles, [
      (Uri.parse(plainUrl), 'English', 'eng'),
    ]);
  });

  testWidgets('a show watched with subtitles off comes up with none', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = remembering({'off': true});
    await prefs.load();

    final harness = await playing(
      tester,
      harnessWith(twoEnglish(), prefs: prefs),
    );

    // Off is a value and not an absence: without somewhere to say it,
    // every episode of the one show this viewer watches undubbed would
    // get subtitles pushed back on.
    expect(harness.engine.externalSubtitles, isEmpty);
    expect(harness.engine.disableSubtitlesCalls, 1);
  });

  testWidgets('turning subtitles off by hand is remembered, and nothing '
      'puts them back', (tester) async {
    useWideViewport(tester);
    final client = FakePrefsClient({
      'subtitlePicks': {
        'shows': [
          {'series': series, 'language': 'English', 'releaseGroup': 'fgt'},
        ],
        'languages': {'English': 9},
      },
    });
    final prefs = AppPrefs(client: client);
    await prefs.load();

    final harness = await playing(
      tester,
      harnessWith(twoEnglish(), prefs: prefs),
    );
    expect(harness.engine.externalSubtitles, hasLength(1));

    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();

    // A pick by hand ends the guessing for this media, so a state change
    // that re-runs the auto-pick does not put the file back on.
    harness.core.setState(
      CoreField.player,
      Map<String, dynamic>.from(harness.fixture),
    );
    await pumpEvents(tester);
    expect(harness.engine.externalSubtitles, hasLength(1));

    // And the memory now says what the viewer said.
    final pick = prefs.subtitlePicks.forSeries(series)!;
    expect(pick.enabled, isFalse);
    expect(pick.language, isNull);
  });

  testWidgets('the pick that is written down is the file that was tapped', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = AppPrefs(client: FakePrefsClient());
    final harness = await playing(
      tester,
      harnessWith([
        upload('en-1', 'eng', plainUrl, releaseGroup: 'PLAIN'),
        upload('sv-1', 'swe', swedishUrl, releaseGroup: 'FGT'),
      ], prefs: prefs),
    );

    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Swedish'));
    await tester.pumpAndSettle();

    // The label the menu prints, not the code the addon sent, so an
    // addon answering `sv` next episode is the same memory; and the
    // group as the file named it, lower-cased.
    final pick = prefs.subtitlePicks.forSeries(series)!;
    expect(pick.language, 'Swedish');
    expect(pick.releaseGroup, 'fgt');
    expect(harness.engine.externalSubtitles.last.$1, Uri.parse(swedishUrl));
    // One pick, one count: this is what the pins are read from.
    expect(prefs.subtitlePicks.languages, {'Swedish': 1});
  });

  testWidgets('the auto-pick writes nothing down', (tester) async {
    useWideViewport(tester);
    final client = FakePrefsClient({
      'subtitlePicks': {
        'shows': [
          {'series': series, 'language': 'English', 'releaseGroup': 'fgt'},
        ],
        'languages': {'English': 9},
      },
    });
    final prefs = AppPrefs(client: client);
    await prefs.load();

    final harness = await playing(
      tester,
      harnessWith(twoEnglish(), prefs: prefs),
    );
    expect(harness.engine.externalSubtitles, hasLength(1));

    // A machine putting back what was remembered is not a judgement, and
    // counting it as one would make twenty-two counts out of a single
    // choice over a season -- after which the two pinned languages could
    // never change again.
    expect(client.writes, isEmpty);
    expect(prefs.subtitlePicks.languages, {'English': 9});
  });

  testWidgets('the session preference still wins over the memory', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = remembering({'language': 'Swedish', 'releaseGroup': 'fgt'});
    await prefs.load();

    // The viewer picked English on the previous episode of this very
    // session; that is what they did a moment ago, and the memory is
    // what they did some other evening.
    final harness = await playing(
      tester,
      harnessWith(
        [
          upload('en-1', 'eng', plainUrl, releaseGroup: 'PLAIN'),
          upload('sv-1', 'swe', swedishUrl, releaseGroup: 'FGT'),
        ],
        prefs: prefs,
        preference: {'enabled': true, 'source': 'external', 'language': 'eng'},
      ),
    );

    expect(harness.engine.externalSubtitles, [
      (Uri.parse(plainUrl), 'English', 'eng'),
    ]);
  });

  testWidgets('a play with no show behind it remembers nothing', (
    tester,
  ) async {
    useWideViewport(tester);
    final client = FakePrefsClient();
    final prefs = AppPrefs(client: client);
    final harness = harnessWith(twoEnglish(), prefs: prefs);
    // An offline file, a deep link straight to a stream: there is no
    // meta item, so there is no show to key a choice on -- the same rule
    // that keeps an unkeyable timing adjustment out of the file.
    harness.selected.remove('metaRequest');
    await playing(tester, harness);

    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(client.writes, isEmpty);
    expect(prefs.subtitlePicks, SubtitlePickMemory.empty);
  });

  testWidgets('a show watched on the file\'s own track comes up on it', (
    tester,
  ) async {
    useWideViewport(tester);
    // The row says English and says the track inside the video was
    // preferred to a download. Both English uploads are on offer, so
    // only the second half of the row can decide this.
    final prefs = remembering({'language': 'English', 'embedded': true});
    await prefs.load();

    final harness = await playingWithTrack(
      tester,
      harnessWith(twoEnglish(), prefs: prefs),
    );

    expect(harness.engine.setSubtitleTrackIds, ['3']);
    expect(harness.engine.externalSubtitles, isEmpty);
  });

  testWidgets('picking the file\'s own track is remembered as one', (
    tester,
  ) async {
    useWideViewport(tester);
    final prefs = AppPrefs(client: FakePrefsClient());
    await prefs.load();
    await playingWithTrack(tester, harnessWith(twoEnglish(), prefs: prefs));

    await tester.tap(find.byTooltip('Subtitles (S)'));
    await tester.pumpAndSettle();
    // The embedded section is drawn above the addons', so the first
    // English row is the file's own track.
    await tester.tap(find.text('English').first);
    await tester.pumpAndSettle();

    // A track in the file has no group and no URL that means anything
    // next episode; the language and the fact that it was a track are
    // the whole of what there is to remember.
    final row = prefs.subtitlePicks.forSeries(series)!;
    expect(row.language, 'English');
    expect(row.embedded, isTrue);
    expect(row.releaseGroup, isNull);
    // And it counts towards the menu's pins like any other pick.
    expect(prefs.subtitlePicks.languages, {'English': 1});
  });
}
