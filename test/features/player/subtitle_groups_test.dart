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
  }) => SubtitleSource(
    SubtitleInfo(<String, dynamic>{'lang': lang, 'url': url, 'label': ?label}),
    addonBase: base,
  );

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

  test('nothing to group is no groups', () {
    expect(groupSubtitlesByLanguage(const []), isEmpty);
  });
}
