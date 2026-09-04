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
    this.ambiguousName = false,
  });

  final SubtitleInfo subtitle;

  /// The addon that offered it, by its installed name (else its manifest
  /// host); a file the stream itself carried is named by its own host.
  final String sourceName;

  /// 1-based position among the files of its language, in merge order.
  final int index;

  /// Whether another file of the same language derives the same name, so
  /// the name on its own does not tell them apart. Set by
  /// [groupSubtitlesByLanguage]; see [name].
  final bool ambiguousName;

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
  ///
  /// A derived name only earns its place by being *different* from its
  /// neighbours, and often it is not: all three Czech files OpenSubtitles
  /// answers for The Godfather are `subtitleFileName: "1.srt"`, and its
  /// Breaking Bad answer has three Romanian `101`s. Those get their
  /// position back on the end (`1 (2)`) -- a name that says nothing is no
  /// worse for it, and three rows reading `1` are unpickable.
  String get name => ambiguousName ? '$_derived ($index)' : _derived;

  /// Every candidate goes through [_short]: they are all addon text, and
  /// a `movieReleaseName` of a hundred and twenty characters is six lines
  /// of one menu row and an addon name pushed off the end of the detail
  /// line beneath it.
  String get _derived =>
      _short(subtitle.label) ??
      _release ??
      _fromFileName(subtitle.subtitleFileName) ??
      _short(subtitle.movieReleaseName) ??
      'Option $index';

  /// The release group, with the format when the addon named both
  /// (`DFN BluRay`). Keyed on the group: a format on its own (`BluRay`)
  /// names no particular upload, so it is not a name.
  String? get _release {
    final group = subtitle.releaseGroup;
    if (group == null) return null;
    final format = subtitle.releaseFormat;
    return _short(format == null ? group : '$group $format');
  }

  /// Past this many characters a name has stopped telling two uploads
  /// apart and the row would only ellipsize it anyway.
  static const _limit = 60;

  /// [text] cut to [_limit] with an ellipsis, or as it stands when it
  /// already fits. Null in, null out.
  static String? _short(String? text) {
    if (text == null || text.length <= _limit) return text;
    // Cutting a string is the one thing that can break a surrogate pair
    // in half, and half a character is what Flutter's text layout refuses
    // to draw -- so the cut goes back through the guard.
    return '${wellFormedText(text.substring(0, _limit))!.trimRight()}\u2026';
  }

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
    return name.isEmpty ? null : _short(name);
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
/// the same file; a genuine 24 fps cut is 0.024 away, which is a tenth of
/// a percent -- seven seconds of drift over a feature, and growing. There
/// is nothing legitimate in between: no addon knows a rate to a
/// thousandth of a frame it did not round from one of the handful of
/// rates film and video are shot at.
const double subtitleFrameRateTolerance = 0.01;

/// The ratios between a video's frame rate and a subtitle's declared one
/// that mean the *same content at the same speed*, so the file plays in
/// sync however far apart the two numbers look.
///
/// A subtitle file is timed in wall-clock seconds, so a declared rate only
/// predicts drift when the two rates imply a different running time for
/// the same material. That is exactly the PAL/NTSC pair this filter exists
/// for -- 25 against 23.976 is a 4.3 % speed-up, four seconds a minute --
/// and it is exactly *not* the telecine and frame-doubling relations
/// inside one family: 23.976 film in a 29.97 container is 5/4 as many
/// frames of the same seconds, and a 50 fps encode of 25 fps material is
/// twice as many. OpenSubtitles' English answer for one Breaking Bad
/// episode is six `23976` files and one `29970`; against the NTSC rip
/// those all belong, and a bare `|a - b|` test would show one of the
/// seven.
const List<double> subtitleFrameRateRatios = [1, 1.25, 2, 2.5];

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
/// - A rate that differs only by telecine or frame doubling is the same
///   cut, because a subtitle is timed in seconds and those relations
///   leave the seconds alone (see [subtitleFrameRateRatios]).
/// - Nothing at all is dropped when [videoFrameRate] is null. An engine
///   that cannot say (or has not said yet) is no evidence against any
///   file.
/// - A language that filtering would empty keeps every one of its files.
///   Losing every Polish subtitle because the container lied about its
///   rate is worse than offering one that drifts.
/// - The file named by [activeId] is never dropped. The rate can arrive
///   after a pick -- the menu is reachable from the moment the controls
///   are -- and taking the playing file out of the list would leave the
///   menu with nothing selected while its subtitles are on screen, and no
///   row anywhere to turn them off from or go back to.
///
/// Embedded tracks never come through here: they are part of the file and
/// declare no rate of their own.
List<SubtitleSource> subtitlesMatchingFrameRate(
  Iterable<SubtitleSource> sources, {
  required double? videoFrameRate,
  String? activeId,
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
      // The exemption is read after `answered`, not folded into it: a
      // language whose only files all mismatch keeps all of them whether
      // or not one of them happens to be playing.
      if (matches[i] ||
          all[i].subtitle.url.toString() == activeId ||
          !answered.contains(
            _languageLabel(all[i].subtitle.lang).toLowerCase(),
          ))
        all[i],
  ];
}

/// Whether [subtitle] was cut for a video running at [videoFrameRate].
/// A rate the addon did not give -- absent, unparsable, or a zero or
/// negative that is no rate at all -- is not a mismatch.
///
/// The two rates are compared after dividing the larger one down by each
/// of [subtitleFrameRateRatios], so the comparison always happens at the
/// content's own rate and [subtitleFrameRateTolerance] keeps its meaning
/// there.
bool _matchesFrameRate(SubtitleInfo subtitle, double videoFrameRate) {
  final milli = subtitle.fpsMilli;
  if (milli == null || milli <= 0) return true;
  final rate = milli / 1000;
  final low = rate < videoFrameRate ? rate : videoFrameRate;
  final high = rate < videoFrameRate ? videoFrameRate : rate;
  return subtitleFrameRateRatios.any(
    (ratio) => (low - high / ratio).abs() <= subtitleFrameRateTolerance,
  );
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
        options: List.unmodifiable(_disambiguated(byLanguage[key]!)),
      ),
  ];
}

/// [options] with every one whose name another file of the same language
/// derives too marked [SubtitleOption.ambiguousName], so the menu never
/// shows one language two rows that read alike.
///
/// The names come from what the addon said about each upload, and an
/// addon repeats itself: the same `subtitleFileName` for three different
/// cuts, the same release group for two. `Option N` was at least unique.
List<SubtitleOption> _disambiguated(List<SubtitleOption> options) {
  final taken = <String, int>{};
  for (final option in options) {
    taken.update(option.name, (count) => count + 1, ifAbsent: () => 1);
  }
  if (taken.length == options.length) return options;
  return [
    for (final option in options)
      if (taken[option.name]! > 1)
        SubtitleOption(
          subtitle: option.subtitle,
          sourceName: option.sourceName,
          index: option.index,
          ambiguousName: true,
        )
      else
        option,
  ];
}
