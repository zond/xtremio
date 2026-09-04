import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/subtitle_groups.dart';

/// Keeping the files that were cut for the video that is playing, and only
/// giving way where believing the numbers would leave a viewer with
/// nothing.
void main() {
  SubtitleSource source(String lang, String url, {Object? fpsMilli}) =>
      SubtitleSource(
        SubtitleInfo(<String, dynamic>{
          'lang': lang,
          'url': url,
          'fpsMilli': ?fpsMilli,
        }),
        addonBase: 'https://opensubtitles-v3.strem.io/manifest.json',
      );

  /// The URLs left of [sources] against a video running at [rate].
  List<String> kept(List<SubtitleSource> sources, double? rate) => [
    for (final source in subtitlesMatchingFrameRate(
      sources,
      videoFrameRate: rate,
    ))
      source.subtitle.url.toString(),
  ];

  test('a rounded rate is the same cut; a neighbouring one is not', () {
    // The boundary the tolerance exists for. OpenSubtitles rounds 23.976
    // to `23980`, four thousandths away: the same file. A real 24 fps cut
    // is twenty-four thousandths away -- a tenth of a percent, seven
    // seconds of drift over a feature.
    final sources = [
      source('eng', 'https://subs/23980.srt', fpsMilli: 23980),
      source('eng', 'https://subs/23976.srt', fpsMilli: 23976),
      source('eng', 'https://subs/24000.srt', fpsMilli: 24000),
      source('eng', 'https://subs/25000.srt', fpsMilli: 25000),
    ];
    expect(kept(sources, 23.976), [
      'https://subs/23980.srt',
      'https://subs/23976.srt',
    ]);
    // The tolerance is what draws that line, not a number to round off.
    expect(subtitleFrameRateTolerance, 0.01);
    expect((23980 / 1000 - 23.976).abs(), lessThan(subtitleFrameRateTolerance));
    expect(
      (24000 / 1000 - 23.976).abs(),
      greaterThan(subtitleFrameRateTolerance),
    );

    // The same list against a 25 fps video keeps the other end of it.
    expect(kept(sources, 25), ['https://subs/25000.srt']);
  });

  test('telecine and frame doubling are the same seconds, so they stay', () {
    // An SRT is timed in seconds, not frames, so a declared rate only
    // means drift when the two rates imply a different running time. NTSC
    // film in a 29.97 container is the same seconds as the 23.976 master
    // -- five frames drawn for every four -- so a `23976` file plays in
    // sync against it, and OpenSubtitles' English answer for one Breaking
    // Bad episode is six of those against a single `29970`.
    final ntsc = [
      source('eng', 'https://subs/23976.srt', fpsMilli: 23976),
      source('eng', 'https://subs/23980.srt', fpsMilli: 23980),
      source('eng', 'https://subs/29970.srt', fpsMilli: 29970),
      source('eng', 'https://subs/59940.srt', fpsMilli: 59940),
      // PAL is the pair the filter exists for: 25 against 29.97 is a
      // different running time whichever way it is scaled.
      source('eng', 'https://subs/25000.srt', fpsMilli: 25000),
    ];
    expect(kept(ntsc, 29.97), [
      'https://subs/23976.srt',
      'https://subs/23980.srt',
      'https://subs/29970.srt',
      'https://subs/59940.srt',
    ]);
    // The same holds seen from the film side, and for the integer family
    // (24 telecined to 30), and for a doubled PAL encode.
    expect(kept(ntsc, 23.976), [
      'https://subs/23976.srt',
      'https://subs/23980.srt',
      'https://subs/29970.srt',
      'https://subs/59940.srt',
    ]);
    final integer = [
      source('eng', 'https://subs/24000.srt', fpsMilli: 24000),
      source('eng', 'https://subs/25000.srt', fpsMilli: 25000),
    ];
    expect(kept(integer, 30), ['https://subs/24000.srt']);
    expect(kept(integer, 50), ['https://subs/25000.srt']);
    // And the ratios are the family relations, not a licence: 25 against
    // 23.976 is still 4.3 % of speed-up and still goes.
    expect(kept([ntsc.first, ntsc.last], 23.976), ['https://subs/23976.srt']);
  });

  test('a file that declares no rate is never the wrong file', () {
    // Most addons declare nothing at all, and OpenSubtitles sends
    // `fpsMilli` on about nine entries in ten; silence is not a mismatch.
    // A zero, a negative and text that is no number are the same silence.
    final sources = [
      source('eng', 'https://subs/silent.srt'),
      source('eng', 'https://subs/zero.srt', fpsMilli: 0),
      source('eng', 'https://subs/negative.srt', fpsMilli: -25000),
      source('eng', 'https://subs/text.srt', fpsMilli: 'unknown'),
      source('eng', 'https://subs/quoted.srt', fpsMilli: '25000'),
    ];
    expect(kept(sources, 23.976), [
      'https://subs/silent.srt',
      'https://subs/zero.srt',
      'https://subs/negative.srt',
      'https://subs/text.srt',
      // A quoted rate is still a rate, and 25 against 23.976 is the wrong
      // cut whichever way the addon spelled it.
    ]);
  });

  test('an unknown video rate filters nothing at all', () {
    // Cast, an offline player, a backend without the property, or simply
    // before the engine has answered: no evidence against any file.
    final sources = [
      source('eng', 'https://subs/23980.srt', fpsMilli: 23980),
      source('eng', 'https://subs/25000.srt', fpsMilli: 25000),
      source('eng', 'https://subs/silent.srt'),
    ];
    expect(kept(sources, null), [
      'https://subs/23980.srt',
      'https://subs/25000.srt',
      'https://subs/silent.srt',
    ]);
  });

  test('a language filtering would empty keeps its mismatched files', () {
    // English has something to offer at 23.976, so its 25 fps upload goes.
    // Polish has nothing else: losing every Polish subtitle because the
    // container lied about its rate is worse than one that drifts.
    final sources = [
      source('eng', 'https://subs/en-23980.srt', fpsMilli: 23980),
      source('eng', 'https://subs/en-25000.srt', fpsMilli: 25000),
      source('pol', 'https://subs/pl-25000.srt', fpsMilli: 25000),
      source('pol', 'https://subs/pl-24000.srt', fpsMilli: 24000),
    ];
    expect(kept(sources, 23.976), [
      'https://subs/en-23980.srt',
      'https://subs/pl-25000.srt',
      'https://subs/pl-24000.srt',
    ]);
  });

  test('the valve opens per language, keyed on what a code means', () {
    // `pl` and `pol` are one row in the menu, so they are one language
    // here: the `pol` match is what makes the `pl` mismatch droppable.
    final sources = [
      source('pl', 'https://subs/pl-25000.srt', fpsMilli: 25000),
      source('pol', 'https://subs/pol-23980.srt', fpsMilli: 23980),
      source('zxx', 'https://subs/zxx-25000.srt', fpsMilli: 25000),
      source('', 'https://subs/none-25000.srt', fpsMilli: 25000),
    ];
    expect(kept(sources, 23.976), [
      'https://subs/pol-23980.srt',
      // A code no language table knows is its own row, and an entry with
      // no code at all is the Unknown row: each keeps its own only file.
      'https://subs/zxx-25000.srt',
      'https://subs/none-25000.srt',
    ]);
  });

  test('what survives keeps the addons order, and nothing is no filtering', () {
    expect(subtitlesMatchingFrameRate(const [], videoFrameRate: 23.976), []);
    final sources = [
      source('eng', 'https://subs/1.srt'),
      source('eng', 'https://subs/2.srt', fpsMilli: 25000),
      source('eng', 'https://subs/3.srt', fpsMilli: 23980),
    ];
    // The first answer still comes first, which is what a tap applies.
    expect(kept(sources, 23.976), ['https://subs/1.srt', 'https://subs/3.srt']);
  });
}
