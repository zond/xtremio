import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/subtitle_groups.dart';

/// Grouping the addons' answers by language: one row per language, the
/// rest of that language's uploads kept behind it.
void main() {
  SubtitleSource source(
    String lang,
    String url, {
    String? base = 'https://opensubtitles-v3.strem.io/manifest.json',
    String? label,
    Map<String, dynamic> properties = const {},
  }) => SubtitleSource(
    SubtitleInfo(<String, dynamic>{
      'lang': lang,
      'url': url,
      'label': ?label,
      ...properties,
    }),
    addonBase: base,
  );

  /// The name of the only option of the only group offered [properties].
  String nameOf(Map<String, dynamic> properties) => groupSubtitlesByLanguage([
    source('eng', 'https://subs/1.srt', properties: properties),
  ]).single.options.single.name;

  test('one row per language, the rest kept as alternatives', () {
    // What OpenSubtitles really answers: many uploads per language.
    final groups = groupSubtitlesByLanguage([
      for (var i = 1; i <= 15; i++) source('eng', 'https://subs/en$i.srt'),
      for (var i = 1; i <= 3; i++) source('spa', 'https://subs/es$i.srt'),
      source('fre', 'https://subs/fr1.srt'),
    ]);
    expect(groups.map((g) => g.language), ['English', 'Spanish', 'French']);
    expect(groups.map((g) => g.options.length), [15, 3, 1]);
    expect(groups.map((g) => g.hasAlternatives), [true, true, false]);

    // Nothing is deleted: every upload is still reachable, numbered so the
    // rows can be told apart.
    expect(groups.first.options.map((o) => o.index), [
      for (var i = 1; i <= 15; i++) i,
    ]);
    expect(groups.first.options.map((o) => o.name).take(3), [
      'Option 1',
      'Option 2',
      'Option 3',
    ]);
  });

  test('the default is the answer of the addon that came first', () {
    final groups = groupSubtitlesByLanguage([
      source('eng', 'https://a/1.srt', base: 'https://a/manifest.json'),
      source('eng', 'https://b/1.srt', base: 'https://b/manifest.json'),
    ]);
    // With nothing playing, the group applies the first file.
    expect(groups.single.chosen(null).id, 'https://a/1.srt');
    expect(groups.single.contains(null), isFalse);

    // Once one of them is playing, that is what the group is and what it
    // re-applies -- which is what keeps a pick visible after regrouping.
    expect(groups.single.contains('https://b/1.srt'), isTrue);
    expect(groups.single.chosen('https://b/1.srt').id, 'https://b/1.srt');
    expect(groups.single.contains('https://elsewhere/1.srt'), isFalse);
  });

  test('groups codes on what they mean, not how they are spelled', () {
    final groups = groupSubtitlesByLanguage([
      source('en', 'https://subs/1.srt'),
      source('eng', 'https://subs/2.srt'),
      source('  ENG ', 'https://subs/3.srt'),
    ]);
    expect(groups, hasLength(1));
    expect(groups.single.language, 'English');
    expect(groups.single.options, hasLength(3));
  });

  test('an unknown code is its own group, shown as itself', () {
    final groups = groupSubtitlesByLanguage([
      source('zxx', 'https://subs/1.srt'),
      source('eng', 'https://subs/2.srt'),
      source('', 'https://subs/3.srt'),
    ]);
    expect(groups.map((g) => g.language), ['zxx', 'English', 'Unknown']);
  });

  test('names the addon a file came from', () {
    final groups = groupSubtitlesByLanguage(
      [
        source(
          'eng',
          'https://subs/1.srt',
          base: 'https://opensubtitles-v3.strem.io/manifest.json',
        ),
        source(
          'eng',
          'https://subs/2.srt',
          base: 'https://other.example/x.json',
        ),
        source('eng', 'https://embedded-in.example/3.srt', base: null),
      ],
      addonName: (url) =>
          url.startsWith('https://opensubtitles-v3') ? 'OpenSubtitles v3' : url,
    );
    expect(groups.single.options.map((o) => o.sourceName), [
      'OpenSubtitles v3',
      'https://other.example/x.json',
      // A file the stream carried names its own host: there is no addon.
      'embedded-in.example',
    ]);
  });

  test('an addon that gave a label is named by it, not by a number', () {
    final groups = groupSubtitlesByLanguage([
      source('spa', 'https://subs/1.srt', label: 'Español (forced)'),
      source('spa', 'https://subs/2.srt'),
    ]);
    expect(groups.single.options.map((o) => o.name), [
      'Español (forced)',
      'Option 2',
    ]);
  });

  test('names an upload by what the addon said about it', () {
    // First hit wins, and every hit is tried in turn: the label beats the
    // release, which beats the filename, which beats the release name.
    const everything = <String, dynamic>{
      'label': 'Espanol (forced)',
      'releaseGroup': 'DFN',
      'releaseFormat': 'BluRay',
      'subtitleFileName': 'The.Godfather.1972.BluRay.srt',
      'movieReleaseName': 'The Godfather 1972 BluRay',
    };
    expect(nameOf(everything), 'Espanol (forced)');
    expect(nameOf({...everything}..remove('label')), 'DFN BluRay');
    // A group with no format is the group alone; a format with no group
    // names no upload, so it is skipped for the filename.
    expect(
      nameOf(
        {...everything}
          ..remove('label')
          ..remove('releaseFormat'),
      ),
      'DFN',
    );
    expect(
      nameOf(
        {...everything}
          ..remove('label')
          ..remove('releaseGroup'),
      ),
      'The Godfather 1972 BluRay',
    );
    expect(
      nameOf(<String, dynamic>{
        'movieReleaseName': everything['movieReleaseName'],
      }),
      'The Godfather 1972 BluRay',
    );
    // Nothing said at all is still the numbered fallback.
    expect(nameOf(const {}), 'Option 1');

    // Every candidate is cut to the same length, not just the filename:
    // a `movieReleaseName` runs to a hundred and twenty characters on the
    // real Breaking Bad answer, and a menu row is not a paragraph.
    expect(nameOf({'label': 'L' * 200}), '${'L' * 60}\u2026');
    expect(nameOf({'movieReleaseName': 'M' * 200}), '${'M' * 60}\u2026');
    expect(nameOf({'releaseGroup': 'G' * 200}), '${'G' * 60}\u2026');
  });

  test('two uploads the addon named alike are still told apart', () {
    // OpenSubtitles answers The Godfather with three Czech files whose
    // `subtitleFileName` is `1.srt` for all three, and Breaking Bad with
    // three Romanian `101`s. Three rows reading `1` are worse than the
    // `Option N` they replaced, so the position goes back on.
    final groups = groupSubtitlesByLanguage([
      for (var i = 1; i <= 3; i++)
        source(
          'cze',
          'https://subs/cs$i.srt',
          properties: const {'subtitleFileName': '1.srt'},
        ),
      // A language whose names already differ is left alone.
      source(
        'eng',
        'https://subs/en1.srt',
        properties: const {'releaseGroup': 'DFN'},
      ),
      source(
        'eng',
        'https://subs/en2.srt',
        properties: const {'releaseGroup': 'ORPHEUS'},
      ),
    ]);
    expect(groups.first.options.map((o) => o.name), [
      '1 (1)',
      '1 (2)',
      '1 (3)',
    ]);
    expect(groups.last.options.map((o) => o.name), ['DFN', 'ORPHEUS']);
    // It is per language, not across the menu: the same name in another
    // language is not a collision, because it is not another row's
    // neighbour.
    final across = groupSubtitlesByLanguage([
      source(
        'cze',
        'https://subs/cs1.srt',
        properties: const {'subtitleFileName': '1.srt'},
      ),
      source(
        'pol',
        'https://subs/pl1.srt',
        properties: const {'subtitleFileName': '1.srt'},
      ),
    ]);
    expect(across.map((g) => g.options.single.name), ['1', '1']);
    // Only some of a language's names repeating marks only those.
    final partial = groupSubtitlesByLanguage([
      source(
        'eng',
        'https://subs/en1.srt',
        properties: const {'releaseGroup': 'DFN'},
      ),
      source(
        'eng',
        'https://subs/en2.srt',
        properties: const {'releaseGroup': 'DFN'},
      ),
      source(
        'eng',
        'https://subs/en3.srt',
        properties: const {'releaseGroup': 'ORPHEUS'},
      ),
    ]);
    expect(partial.single.options.map((o) => o.name), [
      'DFN (1)',
      'DFN (2)',
      'ORPHEUS',
    ]);
  });

  test('cleans a filename into something a menu row can show', () {
    // The directory, the extension and the dots and underscores a release
    // name is written with all go.
    expect(
      nameOf({'subtitleFileName': 'subs/eng/The.Godfather_1972.720p.srt'}),
      'The Godfather 1972 720p',
    );
    // Windows separators too, and runs of separators collapse.
    expect(
      nameOf({'subtitleFileName': r'C:\subs\The...Godfather__1972.SRT'}),
      'The Godfather 1972',
    );
    // Only a subtitle extension is dropped: `x264-DFN` ends a release
    // name and is not one.
    expect(
      nameOf({'subtitleFileName': 'The.Godfather.1972.BluRay.x264-DFN'}),
      'The Godfather 1972 BluRay x264-DFN',
    );
    // A filename that cleans away to nothing is not a name.
    expect(nameOf({'subtitleFileName': 'subs/eng/'}), 'Option 1');
    expect(nameOf({'subtitleFileName': '.srt'}), 'Option 1');
    // A name too long for a row is cut, and the cut never leaves half of
    // a surrogate pair behind -- that is what the text engine refuses.
    final long = nameOf({
      'subtitleFileName': '${'A' * 59}\u{1F44D}${'B' * 20}.srt',
    });
    expect(long, '${'A' * 59}\u2026');
    // The split emoji went whole rather than leaving its head behind.
    expect(
      long.codeUnits.where((unit) => unit >= 0xD800 && unit <= 0xDFFF),
      isEmpty,
    );
  });

  test('nothing to group is no groups', () {
    expect(groupSubtitlesByLanguage(const []), isEmpty);
  });
}
