import '../../core/core.dart';
import '../../core/well_formed_text.dart';
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

  /// What to call this particular upload, first hit wins: the label the
  /// addon gave, else the release it was cut for, else its filename, else
  /// the release name, else its position.
  ///
  /// OpenSubtitles v3 sends no label, so before the pinned fork kept the
  /// addon's own properties (see README, "Pinned upstreams") every one of
  /// fifteen English uploads was `Option N` and the addon's name. The
  /// derived names are what tell them apart now; `Option $index` is still
  /// the floor, for an addon that says nothing but a URL.
  String get name =>
      subtitle.label ??
      _release ??
      _fromFileName(subtitle.subtitleFileName) ??
      subtitle.movieReleaseName ??
      'Option $index';

  /// The release group, with the format when the addon named both
  /// (`DFN BluRay`). Keyed on the group: a format on its own (`BluRay`)
  /// names no particular upload, so it is not a name.
  String? get _release {
    final group = subtitle.releaseGroup;
    if (group == null) return null;
    final format = subtitle.releaseFormat;
    return format == null ? group : '$group $format';
  }

  /// Past this many characters a name has stopped telling two uploads
  /// apart and the row would only ellipsize it anyway.
  static const _limit = 60;

  /// The extensions worth dropping off a subtitle filename, spelled out
  /// rather than matched as "a short trailing dot-group": a release name
  /// ends in `.x264-DFN` or `.H.264`, and a rule that eats those makes
  /// every name worse.
  static final _extension = RegExp(
    r'\.(srt|sub|ssa|ass|vtt|smi|idx|sup|txt)$',
    caseSensitive: false,
  );

  /// [raw] as a menu row: no directory, no extension, the separators a
  /// release name is written with (`.`, `_`) as spaces, and short enough
  /// to read. Null when nothing is left.
  static String? _fromFileName(String? raw) {
    if (raw == null) return null;
    final name = raw
        .split(RegExp(r'[/\\]'))
        .last
        .replaceFirst(_extension, '')
        .replaceAll(RegExp(r'[._\s]+'), ' ')
        .trim();
    if (name.isEmpty) return null;
    if (name.length <= _limit) return name;
    // Cutting a string is the one thing that can break a surrogate pair
    // in half, and half a character is what Flutter's text layout refuses
    // to draw -- so the cut goes back through the guard.
    return '${wellFormedText(name.substring(0, _limit))!.trimRight()}\u2026';
  }
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

/// How far a subtitle's declared rate may sit from the video's own and
/// still be the same cut, in frames per second.
///
/// Wide enough for rounding, narrow enough to catch a different cut.
/// OpenSubtitles' `23980` against a 23.976 container is 0.004 away and is
/// the same file; a genuine 24 fps cut is 0.024 away, and that one drifts
/// a second every fifty. There is nothing legitimate in between: no addon
/// knows a rate to a thousandth of a frame it did not round from one of
/// the handful of rates film and video are shot at.
const double subtitleFrameRateTolerance = 0.01;

/// [sources] without the files cut for a video of a different frame rate,
/// which is what the subtitle menu is built from.
///
/// A subtitle timed for 25 fps played against a 23.976 fps video drifts
/// about four seconds a minute: it is not a worse option, it is the wrong
/// file. But both rates are only what somebody *claims* -- the addon about
/// its upload, the container about itself -- so the filter gives way
/// wherever believing them could leave a viewer with nothing:
///
/// - A file that declares no rate is always kept. Most addons declare
///   none, and silence is not a mismatch.
/// - Nothing at all is dropped when [videoFrameRate] is null. An engine
///   that cannot say (or has not said yet) is no evidence against any
///   file.
/// - A language that filtering would empty keeps every one of its files.
///   Losing every Polish subtitle because the container lied about its
///   rate is worse than offering one that drifts.
///
/// Embedded tracks never come through here: they are part of the file and
/// declare no rate of their own.
List<SubtitleSource> subtitlesMatchingFrameRate(
  Iterable<SubtitleSource> sources, {
  required double? videoFrameRate,
}) {
  final all = sources.toList();
  if (videoFrameRate == null) return all;
  final matches = [
    for (final source in all)
      _matchesFrameRate(source.subtitle, videoFrameRate),
  ];
  // The languages that would still have something to offer. Keyed the way
  // the menu groups them, so "a language filtering would empty" is the
  // same language as the row that would go missing.
  final answered = <String>{
    for (var i = 0; i < all.length; i++)
      if (matches[i]) _languageLabel(all[i].subtitle.lang).toLowerCase(),
  };
  return [
    for (var i = 0; i < all.length; i++)
      if (matches[i] ||
          !answered.contains(
            _languageLabel(all[i].subtitle.lang).toLowerCase(),
          ))
        all[i],
  ];
}

/// Whether [subtitle] was cut for a video running at [videoFrameRate].
/// A rate the addon did not give -- absent, unparsable, or a zero or
/// negative that is no rate at all -- is not a mismatch.
bool _matchesFrameRate(SubtitleInfo subtitle, double videoFrameRate) {
  final milli = subtitle.fpsMilli;
  if (milli == null || milli <= 0) return true;
  return (milli / 1000 - videoFrameRate).abs() <= subtitleFrameRateTolerance;
}

/// The display name a language code is grouped under: what the code
/// *means*, so `en` and `eng` are one language; the code itself when
/// [languageName] does not know it; `Unknown` when there is no code.
String _languageLabel(String lang) {
  final code = lang.trim();
  return code.isEmpty ? 'Unknown' : languageName(code);
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
    final label = _languageLabel(source.subtitle.lang);
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
