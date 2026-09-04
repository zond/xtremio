import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/subtitle_groups.dart';

/// Putting a subtitle cut for another release back in step with the video
/// that is playing, rather than taking it off the menu.
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

  /// The multiplier a file declaring [fpsMilli] gets against a video
  /// running at [rate].
  double speed(Object? fpsMilli, double? rate) => subtitleSpeed(
    source('eng', 'https://subs/1.srt', fpsMilli: fpsMilli).subtitle,
    videoFrameRate: rate,
  );

  /// The URLs of [sources] in the order they are offered against a video
  /// running at [rate].
  List<String> offered(List<SubtitleSource> sources, double? rate) => [
    for (final source in subtitlesByFrameRateFit(sources, videoFrameRate: rate))
      source.subtitle.url.toString(),
  ];

  test('the multiplier is the subtitle rate over the video rate', () {
    // A film of N frames sits at `N / fps_sub` in a subtitle cut for
    // fps_sub and at `N / fps_video` in the picture, so every timestamp
    // wants multiplying by fps_sub / fps_video. The PAL upload on the
    // NTSC film: 25 / 23.976.
    final correction = speed(25000, 23.976);
    expect(correction, closeTo(1.0427, 0.0001));

    // Said as the cue it moves. Frame 1000 of the 25 fps release is
    // written at 40 s in the file; the same frame of the 23.976 fps video
    // arrives at 41.71 s, and the multiplier is what carries it there.
    expect(correction * (1000 / 25), closeTo(1000 / 23.976, 0.001));

    // The reciprocal is the mistake this test exists for. It does not
    // half-fix the drift, it doubles it: the cue lands 3.4 s early where
    // leaving the file alone had it 1.7 s late.
    final reversed = 23.976 / 25;
    final wanted = 1000 / 23.976;
    expect((reversed * 40 - wanted).abs(), greaterThan((40 - wanted).abs()));

    // And the other way round -- an NTSC subtitle on a PAL encode -- is
    // the reciprocal, because the ratio is the same one read backwards.
    expect(speed(23976, 25), closeTo(0.959, 0.001));
  });

  test('a rounded rate is the same cut; a neighbouring one is corrected', () {
    // The boundary the tolerance exists for. OpenSubtitles rounds 23.976
    // to `23980`, four thousandths away: the same file, played as it is.
    // A real 24 fps cut is twenty-four thousandths away -- a tenth of a
    // percent, seven seconds of drift over a feature -- and is re-timed.
    expect(speed(23980, 23.976), 1);
    expect(speed(23976, 23.976), 1);
    expect(speed(24000, 23.976), closeTo(1.001, 0.001));
    // The tolerance is what draws that line, not a number to round off.
    expect(subtitleFrameRateTolerance, 0.01);
    expect((23980 / 1000 - 23.976).abs(), lessThan(subtitleFrameRateTolerance));
    expect(
      (24000 / 1000 - 23.976).abs(),
      greaterThan(subtitleFrameRateTolerance),
    );
  });

  test('telecine and frame doubling are the same seconds, so nothing is '
      'done to them', () {
    // An SRT is timed in seconds, not frames, so a declared rate only
    // means drift when the two rates imply a different running time. NTSC
    // film in a 29.97 container is the same seconds as the 23.976 master
    // -- five frames drawn for every four -- so a `23976` file is already
    // in step, and OpenSubtitles' English answer for one Breaking Bad
    // episode is six of those against a single `29970`.
    expect(speed(23976, 29.97), 1);
    expect(speed(29970, 23.976), 1);
    expect(speed(59940, 23.976), 1);
    expect(speed(24000, 30), 1);
    expect(speed(25000, 50), 1);

    // The correction is taken at the content's own rate, not between the
    // two declared numbers: a subtitle cut for a 50 fps PAL encode is
    // 25 fps material, so against 23.976 film it wants 25 / 23.976 --
    // not twice that, which would run the file at double speed.
    expect(speed(50000, 23.976), closeTo(1.0427, 0.0001));
    // Same reasoning from the other side: a subtitle for a 30 fps
    // telecine of 24 fps film, played against a 25 fps PAL encode.
    expect(speed(30000, 25), closeTo(0.96, 0.001));
  });

  test('a rate nobody declared is never corrected', () {
    // Most addons declare nothing at all, and OpenSubtitles sends
    // `fpsMilli` on about nine entries in ten; silence is not a mismatch.
    // A zero, a negative and text that is no number are the same silence.
    expect(speed(null, 23.976), 1);
    expect(speed(0, 23.976), 1);
    expect(speed(-25000, 23.976), 1);
    expect(speed('unknown', 23.976), 1);
    // A quoted rate is still a rate, and 25 against 23.976 is still the
    // wrong cut whichever way the addon spelled it.
    expect(speed('25000', 23.976), closeTo(1.0427, 0.0001));

    // Cast, an offline player, a backend without the property, or simply
    // before the engine has answered: an unknown video rate re-times
    // nothing, because a guess here breaks a file that was right.
    expect(speed(25000, null), 1);
    expect(speed(null, null), 1);
  });

  test('a language offers what fits first, and offers all of it', () {
    // The file that needs nothing is worth more than the file we have to
    // fix -- `fpsMilli` is a claim about the release an upload was made
    // for, and a claim can be wrong -- and the file that claims nothing
    // is worth more than the one whose own claim says it is a different
    // cut. None of the three is hidden: the drift they were once dropped
    // for is what the multiplier removes.
    final sources = [
      source('eng', 'https://subs/en-25000.srt', fpsMilli: 25000),
      source('eng', 'https://subs/en-silent.srt'),
      source('eng', 'https://subs/en-23980.srt', fpsMilli: 23980),
    ];
    expect(offered(sources, 23.976), [
      'https://subs/en-23980.srt',
      'https://subs/en-silent.srt',
      'https://subs/en-25000.srt',
    ]);
    // The same list against a 25 fps video puts the other end of it
    // first, and still offers every file.
    expect(offered(sources, 25), [
      'https://subs/en-25000.srt',
      'https://subs/en-silent.srt',
      'https://subs/en-23980.srt',
    ]);
  });

  test('the rows keep the addons order, and so does each rank', () {
    expect(subtitlesByFrameRateFit(const [], videoFrameRate: 23.976), isEmpty);
    // Languages stay in the order the addons answered in -- the ranking
    // is inside a language, never across them -- so a Polish file that
    // fits does not push the Polish row above the English one.
    final sources = [
      source('eng', 'https://subs/en-25000.srt', fpsMilli: 25000),
      source('pol', 'https://subs/pl-23980.srt', fpsMilli: 23980),
      source('eng', 'https://subs/en-23976.srt', fpsMilli: 23976),
      source('eng', 'https://subs/en-23980.srt', fpsMilli: 23980),
    ];
    expect(offered(sources, 23.976), [
      // Both English files fit, and the addon that answered first still
      // wins the tie: ranking never reorders inside a rank.
      'https://subs/en-23976.srt',
      'https://subs/en-23980.srt',
      'https://subs/en-25000.srt',
      'https://subs/pl-23980.srt',
    ]);
    // `pl` and `pol` are one row in the menu, so they are one language
    // here as well.
    final polish = [
      source('pl', 'https://subs/pl-25000.srt', fpsMilli: 25000),
      source('pol', 'https://subs/pol-23980.srt', fpsMilli: 23980),
    ];
    expect(offered(polish, 23.976), [
      'https://subs/pol-23980.srt',
      'https://subs/pl-25000.srt',
    ]);
    // With no rate to compare against there is no fit to sort on, and
    // the addons' order stands untouched.
    expect(offered(sources, null), [
      'https://subs/en-25000.srt',
      'https://subs/pl-23980.srt',
      'https://subs/en-23976.srt',
      'https://subs/en-23980.srt',
    ]);
  });
}
