import '../../core/core.dart';
import 'language_names.dart';

/// One subtitle file on offer, with what tells it apart from the other
/// files of the same language.
final class SubtitleOption {
  const SubtitleOption({
    required this.subtitle,
    required this.sourceName,
    required this.index,
  });

  final SubtitleInfo subtitle;

  /// The addon that offered it, by its installed name (else its manifest
  /// host); a file the stream itself carried is named by its own host.
  final String sourceName;

  /// 1-based position among the files of its language, in merge order.
  final int index;

  /// What `PlaybackTracks.activeSubtitleId` holds while this file is on.
  String get id => subtitle.url.toString();

  /// What to call this particular upload: the label the addon gave, else
  /// its position. OpenSubtitles v3 sends no label, and the engine's
  /// `Subtitles` type carries no filename to fall back on (it keeps only
  /// `id`, `lang`, `url`, `label` and `fonts`), so an index plus the addon
  /// name is all there is to tell fifteen English uploads apart.
  String get name => subtitle.label ?? 'Option $index';
}

/// Every file one language was offered in: one row in the subtitle menu,
/// with the rest one press away behind it.
final class SubtitleLanguageGroup {
  const SubtitleLanguageGroup({required this.language, required this.options});

  /// The language's display name, or the code itself when
  /// [languageName] does not know it -- never hidden.
  final String language;

  /// In merge order, so the first is the answer of the addon that came
  /// first, which is what a tap on the group applies.
  final List<SubtitleOption> options;

  bool get hasAlternatives => options.length > 1;

  /// The file this group applies when it is picked: whichever of its
  /// options is playing, else the first.
  SubtitleOption chosen(String? activeId) => options.firstWhere(
    (option) => option.id == activeId,
    orElse: () => options.first,
  );

  /// Whether the file playing right now is one of these -- what keeps the
  /// current selection visible after the list is regrouped.
  bool contains(String? activeId) =>
      activeId != null && options.any((option) => option.id == activeId);
}

/// Groups deduplicated subtitle files by language, one group per language
/// in first-seen (merge) order.
///
/// Codes are grouped on what they *mean*, not on how they are spelled, so
/// an addon answering `en` and one answering `eng` land in the same
/// English group; a code [languageName] does not know is its own group,
/// labelled with the code itself. [addonName] resolves a manifest URL to
/// the addon's installed name; without it the manifest's host is used.
List<SubtitleLanguageGroup> groupSubtitlesByLanguage(
  Iterable<SubtitleSource> sources, {
  String Function(String manifestUrl)? addonName,
}) {
  final order = <String>[];
  final labels = <String, String>{};
  final byLanguage = <String, List<SubtitleOption>>{};
  for (final source in sources) {
    final code = source.subtitle.lang.trim();
    final label = code.isEmpty ? 'Unknown' : languageName(code);
    final key = label.toLowerCase();
    final options = byLanguage.putIfAbsent(key, () {
      order.add(key);
      labels[key] = label;
      return <SubtitleOption>[];
    });
    final base = source.addonBase;
    options.add(
      SubtitleOption(
        subtitle: source.subtitle,
        sourceName: base == null
            ? source.subtitle.url.host
            : addonName?.call(base) ?? Uri.tryParse(base)?.host ?? base,
        index: options.length + 1,
      ),
    );
  }
  return [
    for (final key in order)
      SubtitleLanguageGroup(
        language: labels[key]!,
        options: List.unmodifiable(byLanguage[key]!),
      ),
  ];
}
