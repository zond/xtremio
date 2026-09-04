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
    this.retimed = false,
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

  /// Whether playing this file means correcting its timing
  /// ([subtitleSpeed]). Set by [groupSubtitlesByLanguage], which is the
  /// only place that knows what the video runs at.
  ///
  /// It is worth a word on the row: a viewer whose subtitles drift anyway
  /// needs to know we touched the file before they go hunting for a
  /// different one. Only that -- not the rate, which is a number to
  /// reason about rather than an answer.
  final bool retimed;

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
/// still need no correction, in frames per second.
///
/// Wide enough for rounding, narrow enough to catch a different cut.
/// OpenSubtitles' `23980` against a 23.976 container is 0.004 away and is
/// the same file; a genuine 24 fps cut is 0.024 away, which is a tenth of
/// a percent -- seven seconds of drift over a feature, and growing. There
/// is nothing legitimate in between: no addon knows a rate to a
/// thousandth of a frame it did not round from one of the handful of
/// rates film and video are shot at.
const double subtitleFrameRateTolerance = 0.01;

/// The ratios between two frame rates that mean the *same content at the
/// same speed*, so a file declaring one is in step with a video running
/// at the other however far apart the numbers look.
///
/// A subtitle file is timed in wall-clock seconds, so a declared rate
/// only implies drift when the two rates imply a different running time
/// for the same material. That is exactly the PAL/NTSC pair the
/// correction exists for -- 25 against 23.976 is a 4.3 % speed-up, four
/// seconds a minute -- and it is exactly *not* the telecine and
/// frame-doubling relations inside one family: 23.976 film in a 29.97
/// container is 5/4 as many frames of the same seconds, and a 50 fps
/// encode of 25 fps material is twice as many. OpenSubtitles' English
/// answer for one Breaking Bad episode is six `23976` files and one
/// `29970`; against the NTSC rip all seven are already in step, and a
/// bare `fps_sub / fps_video` would push six of them out of it.
const List<double> subtitleFrameRateRatios = [1, 1.25, 2, 2.5];

/// What libmpv's `sub-speed` has to be for [subtitle] to keep time with a
/// video running at [videoFrameRate]: `fps_sub / fps_video`, and `1.0`
/// wherever there is nothing to correct.
///
/// A film of N frames sits at `N / fps_sub` in a subtitle cut for
/// `fps_sub` and at `N / fps_video` in the picture, so every timestamp
/// wants multiplying by `fps_sub / fps_video`: a 25 fps subtitle on a
/// 23.976 fps video runs 1.0427 times as long. The reciprocal is the
/// mistake to make here, and it doubles the drift rather than removing
/// it.
///
/// Three things are not a correction, and each answers `1.0`:
///
/// - A rate the addon did not give -- absent, unparsable, or a zero or
///   negative that is no rate at all. Most addons declare none, and
///   OpenSubtitles sends `fpsMilli` on about nine entries in ten.
/// - A [videoFrameRate] of null. Cast, offline, a fake, a container that
///   says nothing, a read that threw: an engine that cannot say is no
///   evidence about any file, and a guess here re-times a file that was
///   right.
/// - Two rates a telecine or a doubling apart, which are the same
///   seconds already (see [subtitleFrameRateRatios]).
///
/// The ratio is taken between the two *content* rates, not between the
/// two declared numbers: a subtitle cut for a 50 fps PAL encode is
/// 25 fps material and a 29.97 fps container is 23.976 fps film, so the
/// pair needs 25/23.976 and not the 25/29.97 the declared numbers read
/// as. [subtitleFrameRateTolerance] keeps its meaning there too, counted
/// in frames of the video that is playing.
double subtitleSpeed(SubtitleInfo subtitle, {required double? videoFrameRate}) {
  final declared = _declaredFrameRate(subtitle);
  if (declared == null || videoFrameRate == null) return 1;
  final speed = _sameSecondsRatio(declared, videoFrameRate);
  // A rate that divides out to nothing or to infinity is not a rate; the
  // guards above have caught every real one, and this is the arithmetic's
  // own floor.
  if (!speed.isFinite || speed <= 0) return 1;
  // The tolerance is frames, so the ratio is read back as the rate it
  // puts the subtitle at against the video's own.
  return (speed - 1).abs() * videoFrameRate <= subtitleFrameRateTolerance
      ? 1
      : speed;
}

/// The rate [subtitle] says it was cut for, or null when the addon said
/// nothing usable: absent, unparsable, or a zero or negative that is no
/// rate at all.
double? _declaredFrameRate(SubtitleInfo subtitle) {
  final milli = subtitle.fpsMilli;
  return milli == null || milli <= 0 ? null : milli / 1000;
}

/// The ratio between [rate] and [videoFrameRate] nearest 1: every member
/// of the subtitle's frame-rate family over every member of the video's,
/// since a telecine or a doubling leaves the seconds alone on either
/// side.
///
/// Both sides have to be reduced, not the subtitle's alone. A 50 fps PAL
/// encode is 25 fps material and a 29.97 fps container is 23.976 fps
/// film, but no single step of [subtitleFrameRateRatios] carries 50 into
/// 29.97's neighbourhood: reducing one side lands on 25 against a
/// declared 29.97 and answers 0.834, which leaves the file five times
/// further out than playing it untouched would have.
///
/// Nearest *to 1* rather than nearest in frames, because the answer has
/// to be the same whichever end of a family the two numbers are written
/// at, and a difference in frames is not -- it puts 100 against 25 on
/// 40/25 rather than on the 50/50 that is the same cut.
double _sameSecondsRatio(double rate, double videoFrameRate) {
  var nearest = rate / videoFrameRate;
  for (final subtitleRate in _frameRateFamily(rate)) {
    for (final videoRate in _frameRateFamily(videoFrameRate)) {
      final ratio = subtitleRate / videoRate;
      if ((ratio - 1).abs() < (nearest - 1).abs()) nearest = ratio;
    }
  }
  return nearest;
}

/// [rate] and the rates that are the same seconds as it: [rate] scaled by
/// each of [subtitleFrameRateRatios] either way, since telecine and frame
/// doubling go in both directions.
Iterable<double> _frameRateFamily(double rate) sync* {
  for (final ratio in subtitleFrameRateRatios) {
    yield rate * ratio;
    yield rate / ratio;
  }
}

/// Where a file sits in its language's order, best first.
enum _FrameRateFit {
  /// A declared rate the video is already in step with: nothing to
  /// correct, nothing to get wrong.
  matched,

  /// No declared rate. Nothing says it drifts and nothing says it does
  /// not; it is played as it stands.
  undeclared,

  /// A declared rate that differs, so [subtitleSpeed] re-times it.
  corrected,
}

/// [sources] with each language's files ordered by how little has to be
/// done to them: an exact match first, then the ones that declared no
/// rate, then the ones a multiplier has to fix.
///
/// An addon's `fpsMilli` is a claim about the release the upload was made
/// for, and a claim can be wrong -- so a file that needs nothing is worth
/// more than a file we have to fix, and a file that says nothing is worth
/// more than a file whose own claim says it is the wrong cut. Nothing is
/// dropped: every file the addons offered is still on the list, because
/// the drift they were once hidden for is correctable.
///
/// The order *between* languages is untouched -- the menu's rows stay in
/// the addons' answer order -- and so is the order inside each of the
/// three ranks, so the addon that answered first still wins a tie.
///
/// A null [videoFrameRate] ranks nothing: with no rate to compare against
/// there is no fit to sort on, and the addons' order stands.
List<SubtitleSource> subtitlesByFrameRateFit(
  Iterable<SubtitleSource> sources, {
  required double? videoFrameRate,
}) {
  final all = sources.toList();
  if (videoFrameRate == null) return all;
  final order = <String>[];
  final byLanguage = <String, List<SubtitleSource>>{};
  for (final source in all) {
    // Keyed the way the menu groups them, so "within a language" is the
    // same language as the row the files are listed under.
    final key = _languageLabel(source.subtitle.lang).toLowerCase();
    byLanguage
        .putIfAbsent(key, () {
          order.add(key);
          return <SubtitleSource>[];
        })
        .add(source);
  }
  return [
    for (final key in order)
      // Bucketed rather than sorted: `List.sort` is not stable, and the
      // order inside a rank is the addons' answer order, which is what
      // decides the file a language row applies.
      for (final fit in _FrameRateFit.values)
        for (final source in byLanguage[key]!)
          if (_fitOf(source.subtitle, videoFrameRate) == fit) source,
  ];
}

/// Which of the three ranks [subtitle] is in against [videoFrameRate].
_FrameRateFit _fitOf(SubtitleInfo subtitle, double videoFrameRate) {
  if (_declaredFrameRate(subtitle) == null) return _FrameRateFit.undeclared;
  return subtitleSpeed(subtitle, videoFrameRate: videoFrameRate) == 1
      ? _FrameRateFit.matched
      : _FrameRateFit.corrected;
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
///
/// [videoFrameRate] is what the video is running at, and is only read to
/// mark the files that will be re-timed against it
/// ([SubtitleOption.retimed]). The order the groups and their options
/// come out in is the order [sources] arrived in, so the ranking is
/// [subtitlesByFrameRateFit]'s to do first.
List<SubtitleLanguageGroup> groupSubtitlesByLanguage(
  Iterable<SubtitleSource> sources, {
  String Function(String manifestUrl)? addonName,
  double? videoFrameRate,
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
        retimed:
            subtitleSpeed(source.subtitle, videoFrameRate: videoFrameRate) != 1,
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
          retimed: option.retimed,
        )
      else
        option,
  ];
}
