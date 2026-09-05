import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/subtitle_groups.dart';
import 'package:xtremio/features/player/track_menus.dart';

/// Telling which of a language's uploads was cut for the video that is
/// actually playing, from what the addon says about it.
void main() {
  /// One addon answer for [url], claiming [releaseGroup] and
  /// [movieReleaseName] as what it was cut for.
  SubtitleSource upload(
    String url, {
    String lang = 'eng',
    String? releaseGroup,
    String? movieReleaseName,
    Object? g,
  }) => SubtitleSource(
    SubtitleInfo(<String, dynamic>{
      'lang': lang,
      'url': url,
      'releaseGroup': ?releaseGroup,
      'movieReleaseName': ?movieReleaseName,
      'g': ?g,
    }),
    addonBase: 'https://opensubtitles-v3.strem.io/manifest.json',
  );

  bool matches(SubtitleSource source, String? release) =>
      subtitleMatchesRelease(source.subtitle, release: release);

  const playing = 'the.godfather.1972.1080p.bluray.x264-dfn.mkv';

  test('a claim is matched whole, however either side is written', () {
    // Release names are written every way there is, and the two sides
    // are almost never written the same way: the addon sends the name
    // with spaces and the file on disk has dots.
    expect(
      matches(upload('https://subs/1.srt', releaseGroup: 'DFN'), playing),
      isTrue,
    );
    expect(
      matches(
        upload(
          'https://subs/2.srt',
          movieReleaseName: 'The Godfather 1972 1080p BluRay x264-DFN',
        ),
        playing,
      ),
      isTrue,
    );
    // Underscores, brackets and case are separators and noise alike, on
    // both sides.
    expect(
      matches(
        upload('https://subs/3.srt', releaseGroup: '[dfn]'),
        'The_Godfather_1972_1080p_BluRay_x264_DFN.mkv',
      ),
      isTrue,
    );
    // And an accented title is one token rather than three, so it can
    // match at all.
    expect(
      matches(
        upload('https://subs/4.srt', movieReleaseName: 'Amélie 2001 DFN'),
        'Amélie.2001.DFN.mkv',
      ),
      isTrue,
    );
  });

  test('a false match is worse than none, so these are not matches', () {
    // Part of a word. A group tag is a whole token or it is nothing:
    // matched as a substring, `DFN` claims a file cut by DFNX.
    expect(
      matches(
        upload('https://subs/1.srt', releaseGroup: 'DFN'),
        'The.Godfather.1972.1080p.BluRay.x264-DFNX.mkv',
      ),
      isFalse,
    );
    // Tokens that appear scattered rather than together. Both words are
    // in the filename; what they describe is a kind of encode, and
    // every 1080p BluRay rip of this film would answer the same.
    expect(
      matches(
        upload('https://subs/2.srt', movieReleaseName: 'BluRay x264'),
        'The.Godfather.1972.1080p.BluRay.DTS.x264-DFN.mkv',
      ),
      isFalse,
    );
    // A lone token that names nothing: a year, a resolution's number, a
    // two-letter tag. An addon fills these fields with whatever it
    // managed to parse, and a bare number is what a bad parse leaves.
    for (final claim in ['1972', '1080', 'HD']) {
      expect(
        matches(upload('https://subs/3.srt', releaseGroup: claim), playing),
        isFalse,
        reason: '$claim names no upload',
      );
    }
    // A group of three characters is a real one and does match, which is
    // the line the rule above is drawn just under.
    expect(
      matches(upload('https://subs/4.srt', releaseGroup: 'DFN'), playing),
      isTrue,
    );
    // An addon that claimed nothing, and a video nothing has named yet
    // -- an offline play, a torrent whose server has not opened the file
    // -- are both simply unknown.
    expect(matches(upload('https://subs/5.srt'), playing), isFalse);
    expect(
      matches(upload('https://subs/6.srt', releaseGroup: 'DFN'), null),
      isFalse,
    );
    expect(
      matches(upload('https://subs/7.srt', releaseGroup: 'DFN'), ''),
      isFalse,
    );
  });

  test('a title and an episode are not a claim about this upload', () {
    // Measured against what OpenSubtitles really answers for Gilmore
    // Girls S01E01: of the twelve files whose claim appears in this
    // filename, eleven claim nothing but the show, the episode and its
    // title -- which every upload of that episode carries. Taken as
    // release matches they are marked "same release" on no evidence and
    // sent to the head of their language, which is the file the row
    // applies and the file the auto-pick plays with nobody looking.
    const episode =
        'gilmore.girls.s01e01.pilot.1080p.amzn.web-dl.ddp2.0.h.264-playweb.mkv';
    for (final claim in [
      'Gilmore Girls - S01E01 - Pilot',
      'Gilmore Girls S01E01',
      'gilmore_girls_s01e01_pilot',
      'Gilmore Girls',
    ]) {
      expect(
        matches(upload('https://subs/1.srt', movieReleaseName: claim), episode),
        isFalse,
        reason: '$claim names an episode, not an upload',
      );
    }
    // The one that is genuine still is: a release group is never the
    // show's title, so it counts wherever in the name it sits.
    expect(
      matches(upload('https://subs/2.srt', releaseGroup: 'playWEB'), episode),
      isTrue,
    );
    // And so does a name that runs to the end of the file's own -- that
    // is the whole release rather than the front of it.
    expect(
      matches(
        upload(
          'https://subs/3.srt',
          movieReleaseName: 'Gilmore Girls S01E01 Pilot 1080p AMZN WEB-DL DDP2.0 H.264-playWEB',
        ),
        episode,
      ),
      isTrue,
    );
  });

  test('the container the claim was written with is not the release', () {
    // The addon spells its claim with the extension it saw and the
    // server opened a remux of the same release; the name in between is
    // what says which release it is.
    const claim = 'Gilmore Girls S01E01 1080p WEB-DL DD+ 2.0 x264-TrollHD.mkv';
    for (final playing in [
      'gilmore girls s01e01 1080p web-dl dd+ 2.0 x264-trollhd.mkv',
      'gilmore girls s01e01 1080p web-dl dd+ 2.0 x264-trollhd.mp4',
    ]) {
      expect(
        matches(upload('https://subs/1.srt', movieReleaseName: claim), playing),
        isTrue,
        reason: playing,
      );
    }
  });

  /// The URLs of [sources] in the order they are offered for a video
  /// named [release] of [series], with [memory] as what the viewer has
  /// already fixed.
  List<String> offered(
    List<SubtitleSource> sources, {
    String? release,
    String? series,
    SubtitleSyncMemory memory = SubtitleSyncMemory.empty,
  }) => [
    for (final source in subtitlesByRelease(
      sources,
      release: release,
      series: series,
      memory: memory,
    ))
      source.subtitle.url.toString(),
  ];

  test('a language offers what was cut for this release first', () {
    final sources = [
      upload('https://subs/yts.srt', releaseGroup: 'YTS'),
      upload('https://subs/silent.srt'),
      upload('https://subs/dfn.srt', releaseGroup: 'DFN'),
    ];
    expect(offered(sources, release: playing), [
      'https://subs/dfn.srt',
      // Nothing is dropped: the rest are still offered, in the order the
      // addons answered, because that is the order a row applies.
      'https://subs/yts.srt',
      'https://subs/silent.srt',
    ]);
    // With nothing to compare against, the addons' order is the whole of
    // what is known.
    expect(offered(sources), [
      'https://subs/yts.srt',
      'https://subs/silent.srt',
      'https://subs/dfn.srt',
    ]);
    expect(
      subtitlesByRelease(
        const [],
        release: playing,
        series: 'tt0068646',
        memory: SubtitleSyncMemory.empty,
      ),
      isEmpty,
    );
  });

  test('then a group the viewer has already fixed for this show', () {
    // The second rank is worth having for one reason: the correction is
    // put back when the file is applied, so it arrives fixed.
    const series = 'tt0068646';
    final memory = SubtitleSyncMemory.empty.remembering(
      series: series,
      group: '6',
      release: null,
      speed: 25 / 23.976,
      shiftSeconds: 0,
    );
    final sources = [
      upload('https://subs/plain.srt', releaseGroup: 'PLAIN'),
      upload('https://subs/six.srt', releaseGroup: 'SIX', g: 6),
      upload('https://subs/dfn.srt', releaseGroup: 'DFN'),
    ];
    expect(offered(sources, release: playing, series: series, memory: memory), [
      // The release match still outranks it: it is evidence about this
      // video, where the memory is evidence about a group.
      'https://subs/dfn.srt',
      'https://subs/six.srt',
      'https://subs/plain.srt',
    ]);
    // Another show's correction says nothing about this one, and neither
    // does one made for a group nobody here belongs to.
    expect(
      offered(sources, release: playing, series: 'tt0063350', memory: memory),
      [
        'https://subs/dfn.srt',
        'https://subs/plain.srt',
        'https://subs/six.srt',
      ],
    );
  });

  test('a correction that would not be applied does not rank either', () {
    // A shift belongs to one video release, so one measured against
    // another is not put back here -- and a rank that promised it would
    // be would be promising a fix that never arrives. The rank asks the
    // memory exactly what the player asks it.
    const series = 'tt0068646';
    final elsewhere = SubtitleSyncMemory.empty.remembering(
      series: series,
      group: '6',
      release: 'the.godfather.1972.720p.web.h264-yts.mkv',
      speed: null,
      shiftSeconds: 0.3,
    );
    final sources = [
      upload('https://subs/plain.srt', releaseGroup: 'PLAIN'),
      upload('https://subs/six.srt', releaseGroup: 'SIX', g: 6),
    ];
    expect(
      offered(sources, release: playing, series: series, memory: elsewhere),
      ['https://subs/plain.srt', 'https://subs/six.srt'],
    );
    // Made against this release, it is put back, so it ranks.
    final here = SubtitleSyncMemory.empty.remembering(
      series: series,
      group: '6',
      release: playing,
      speed: null,
      shiftSeconds: 0.3,
    );
    expect(offered(sources, release: playing, series: series, memory: here), [
      'https://subs/six.srt',
      'https://subs/plain.srt',
    ]);
  });

  test('the rows keep the addons order, and so does each rank', () {
    // Languages stay in the order the addons answered in -- the ranking
    // is inside a language, never across them -- so a Polish file cut
    // for this release does not push the Polish row above the English
    // one.
    final sources = [
      upload('https://subs/en-yts.srt', releaseGroup: 'YTS'),
      upload('https://subs/pl-dfn.srt', lang: 'pol', releaseGroup: 'DFN'),
      upload('https://subs/en-dfn-1.srt', releaseGroup: 'DFN'),
      upload('https://subs/en-dfn-2.srt', releaseGroup: 'DFN'),
    ];
    expect(offered(sources, release: playing), [
      // Both English matches are first, and the addon that answered
      // first still wins the tie: ranking never reorders inside a rank.
      'https://subs/en-dfn-1.srt',
      'https://subs/en-dfn-2.srt',
      'https://subs/en-yts.srt',
      'https://subs/pl-dfn.srt',
    ]);
    // `pl` and `pol` are one row in the menu, so they are one language
    // here as well.
    expect(
      offered([
        upload('https://subs/pl-yts.srt', lang: 'pl', releaseGroup: 'YTS'),
        upload('https://subs/pol-dfn.srt', lang: 'pol', releaseGroup: 'DFN'),
      ], release: playing),
      ['https://subs/pol-dfn.srt', 'https://subs/pl-yts.srt'],
    );
  });

  test('the row says which file was cut for what is playing', () {
    final groups = groupSubtitlesByLanguage(
      [
        upload('https://subs/other.srt', releaseGroup: 'YTS'),
        upload('https://subs/mine.srt', releaseGroup: 'DFN'),
      ],
      addonName: (_) => 'OpenSubtitles v3',
      release: playing,
    );
    final options = groups.single.options;
    expect(options.map((option) => option.matchesRelease), [false, true]);
    // The mark is two words beside the addon that offered it, and no
    // rate and no verdict about the file's timing.
    expect(
      SubtitleMenu.optionDetail(options[1]),
      'OpenSubtitles v3 · ${SubtitleMenu.releaseNote}',
    );
    expect(SubtitleMenu.optionDetail(options[0]), 'OpenSubtitles v3');

    // Nothing to compare against marks nobody: knowing nothing has to
    // look like knowing nothing.
    final unnamed = groupSubtitlesByLanguage([
      upload('https://subs/mine.srt', releaseGroup: 'DFN'),
    ], addonName: (_) => 'OpenSubtitles v3');
    expect(unnamed.single.options.single.matchesRelease, isFalse);
  });

  test('a file whose name another one derives too keeps its mark', () {
    // Two uploads one addon named alike get their position back on the
    // end, which rebuilds the option -- and a rebuild that dropped the
    // mark would take it off exactly the rows most in need of telling
    // apart.
    final groups = groupSubtitlesByLanguage(
      [
        upload('https://subs/1.srt', releaseGroup: 'DFN'),
        upload('https://subs/2.srt', releaseGroup: 'DFN'),
      ],
      addonName: (_) => 'OpenSubtitles v3',
      release: playing,
    );
    final options = groups.single.options;
    expect(options.map((option) => option.name), ['DFN (1)', 'DFN (2)']);
    expect(options.every((option) => option.matchesRelease), isTrue);
  });
}
