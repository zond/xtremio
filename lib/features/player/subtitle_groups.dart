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
    this.matchesRelease = false,
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

  /// Whether the addon says this file was cut for the very release that
  /// is playing ([subtitleMatchesRelease]). Set by
  /// [groupSubtitlesByLanguage] from the name the player knows the video
  /// by, and worth a word on the row: it is why the file is at the head
  /// of its language.
  final bool matchesRelease;

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

/// The smallest multiplier libmpv's `sub-speed` accepts (the property is
/// `<0.1-10.0>`), and with [maxSubtitleSpeed] the range a value has to
/// fall in to be set at all.
///
/// media_kit writes the property with `mpv_set_property_string` and
/// discards its return code, so a value outside the range is refused in
/// silence -- nothing throws, and the multiplier the *previous* file
/// left behind stays in force while the panel claims a new one. Every
/// path that can produce a multiplier keeps well clear of it on its own
/// -- a calibration and a match each believe a ratio only within about
/// a tenth of the file's own timing, where the largest real mismatch,
/// PAL against film, is 4.3 % -- and this pair is what a stored one is
/// checked against on the way back in
/// (`PlayerScreen._rememberedSpeed`), since a preferences file will
/// hold whatever somebody puts in it.
const double minSubtitleSpeed = 0.1;

/// The largest multiplier libmpv's `sub-speed` accepts; see
/// [minSubtitleSpeed] for what falling outside the range costs.
const double maxSubtitleSpeed = 10;

/// Whether the addon says [subtitle] was cut for [release] -- the video
/// file that is playing, by the best name the player knows it by.
///
/// Two of the addon's claims are compared, and both are claims about
/// *which upload this is*: the release group (`DFN`) and the whole
/// release name (`The Godfather 1972 1080p BluRay x264-DFN`). A match
/// says more about timing than any declared rate does, because two
/// subtitle files cut for one release are in step with it by
/// construction, where a rate is only a claim about where the upload
/// came from.
///
/// Release names are written every way there is -- dots, underscores,
/// spaces, dashes, brackets, any case -- so both sides are cut into
/// lower-case runs of letters and digits, and the claim has to appear in
/// the playing file's name as a whole run of whole tokens.
///
/// A false match is worse than no match: it puts a file at the head of
/// its language, which is the file the row applies and the file the
/// auto-pick plays with nobody looking. So these are deliberately *not*
/// matches:
///
/// - Part of a word. `DFN` does not match `dfnx264`, because tokens are
///   compared whole and never as a substring of one.
/// - Tokens that appear scattered through the name rather than together.
///   `1080p` and `bluray` picked out of opposite ends of a filename
///   describe a kind of encode, not this encode.
/// - A lone token that is bare digits, or shorter than three characters:
///   a year, a resolution, a season number, an initialism. None of those
///   name an upload, and an addon fills these fields with whatever it
///   managed to parse.
///
/// A claim that matches *every* file of a language -- the film's title
/// on its own -- costs nothing, since a rank keeps the addons' own order
/// inside it, and promoting all of them promotes none of them.
bool subtitleMatchesRelease(SubtitleInfo subtitle, {required String? release}) {
  if (release == null) return false;
  final playing = _withoutContainer(_releaseTokens(release));
  if (playing.isEmpty) return false;
  // A release group is never the film's title, so it counts wherever in
  // the name it sits. A release name can be nothing *but* the title, so
  // it is held to more.
  return _claims(playing, subtitle.releaseGroup, wholeName: false) ||
      _claims(playing, subtitle.movieReleaseName, wholeName: true);
}

/// Whether [claim] names the upload whose filename is [playing].
///
/// [wholeName] is set for a claim that is supposed to be a release name
/// rather than a group, and holds it to one more rule: a run that starts
/// at the front of the playing name and stops short of its end is the
/// title and the episode, which every upload of that episode carries.
/// `Gilmore Girls - S01E01 - Pilot` is what an addon sends when it has
/// only the episode to go on, and eleven of the twelve OpenSubtitles
/// answers whose claim appears in one real filename are of that shape --
/// so taken as release matches they mark a file "same release" on no
/// evidence and put it at the head of its language, which is the file
/// the row applies and the file the auto-pick plays. A claim that runs
/// to the end of the name is the whole name; one that starts inside it
/// has already got past the title.
bool _claims(List<String> playing, String? claim, {required bool wholeName}) {
  if (claim == null) return false;
  final tokens = _withoutContainer(_releaseTokens(claim));
  if (!_namesAnUpload(tokens)) return false;
  final at = _runStart(playing, tokens);
  if (at < 0) return false;
  return !wholeName || at > 0 || tokens.length == playing.length;
}

/// [name] as the tokens a release is compared on: lower-case runs of
/// letters and digits, with every separator a release name is written
/// with dropped.
///
/// Letters and digits by their Unicode classes rather than `a-z0-9`, so
/// an accented title is one token on both sides instead of being split
/// at every accent.
List<String> _releaseTokens(String name) => [
  for (final token in name.toLowerCase().split(_separators))
    if (token.isNotEmpty) token,
];

final RegExp _separators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final RegExp _bareDigits = RegExp(r'^\p{N}+$', unicode: true);

/// Whether [tokens] name a particular upload rather than something every
/// upload of the film shares. See [subtitleMatchesRelease] for why one
/// token is held to more than the rest are.
bool _namesAnUpload(List<String> tokens) {
  if (tokens.isEmpty) return false;
  if (tokens.length > 1) return true;
  final only = tokens.single;
  return only.length >= 3 && !_bareDigits.hasMatch(only);
}

/// Where [needle] appears in [haystack] as a contiguous run, token for
/// token, and -1 when it does not.
int _runStart(List<String> haystack, List<String> needle) {
  for (var start = 0; start + needle.length <= haystack.length; start++) {
    var same = true;
    for (var i = 0; i < needle.length; i++) {
      if (haystack[start + i] != needle[i]) {
        same = false;
        break;
      }
    }
    if (same) return start;
  }
  return -1;
}

/// [tokens] without a trailing video container extension.
///
/// The extension is the one part of a filename that says nothing about
/// which release it is, and the two sides disagree about it all the
/// time: the addon spells its claim with the container it saw and the
/// server opened a remux of the same release. Dropping it is also what
/// lets "runs to the end of the name" mean the end of the name proper.
///
/// Spelled out rather than matched as "a short trailing dot-group", for
/// the reason [SubtitleOption._extension] is: a release name ends in
/// `.x264-DFN` or `.H.264`, and a rule that ate those would take a
/// group tag off every name it saw. Never the only token, so a claim
/// that is nothing but an extension stays the nothing it is.
List<String> _withoutContainer(List<String> tokens) =>
    tokens.length > 1 && _containers.contains(tokens.last)
    ? tokens.sublist(0, tokens.length - 1)
    : tokens;

const Set<String> _containers = {
  'mkv',
  'mp4',
  'm4v',
  'avi',
  'mov',
  'ts',
  'm2ts',
  'mts',
  'webm',
  'wmv',
  'asf',
  'flv',
  'mpg',
  'mpeg',
  'ogm',
  'ogv',
  'divx',
  'vob',
  'rm',
  'rmvb',
  '3gp',
};

/// Where a file sits in its language's order, best first.
enum _ReleaseFit {
  /// The addon says it was cut for the release that is playing
  /// ([subtitleMatchesRelease]), so it is near-certainly in sync: two
  /// files made for one release are in step with it by construction.
  release,

  /// From a subtitle group the viewer has already corrected for this
  /// show, so the correction goes back on the moment it is applied and
  /// the file arrives fixed.
  adjusted,

  /// Everything else, in the order the addons answered.
  offered,
}

/// [sources] with each language's files ordered by what is actually
/// known about them: the ones the addon says were cut for the release
/// that is playing first, then the ones from a group the viewer has
/// already adjusted for [series], then the rest as the addons gave them.
///
/// The declared frame rate used to order this and no longer does. It is
/// a claim about the release an upload was made for, and the evidence
/// says that is a claim about *provenance* and not about timing: ten
/// English files for one film declaring six different rates all end
/// within 1 % of the same runtime. What names a release says more,
/// because two files cut for one release keep its time.
///
/// [release] and [series] name what is playing (null for either -- an
/// offline play, a torrent nothing has named the file of, a stream with
/// no meta behind it -- simply answers nothing for that rank), and
/// [memory] is what the viewer has already fixed. The second rank asks
/// [memory] exactly what `PlayerScreen._resetSubtitleTiming` will ask it
/// when the file goes on screen, so "already adjusted" means the
/// correction really is put back and not merely stored: a shift belongs
/// to one release, and one measured against another is not this video's.
///
/// The order *between* languages is untouched -- the menu's rows stay in
/// the addons' answer order -- and so is the order inside each rank, so
/// the addon that answered first still wins a tie. That matters more
/// than it looks: the head of a language is the file its row applies and
/// the file the auto-pick plays. Nothing is dropped or hidden.
List<SubtitleSource> subtitlesByRelease(
  Iterable<SubtitleSource> sources, {
  required String? release,
  required String? series,
  required SubtitleSyncMemory memory,
}) {
  final order = <String>[];
  final byLanguage = <String, List<SubtitleSource>>{};
  for (final source in sources) {
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
      for (final fit in _ReleaseFit.values)
        for (final source in byLanguage[key]!)
          if (_fitOf(
                source.subtitle,
                release: release,
                series: series,
                memory: memory,
              ) ==
              fit)
            source,
  ];
}

/// Which of the three ranks [subtitle] is in.
_ReleaseFit _fitOf(
  SubtitleInfo subtitle, {
  required String? release,
  required String? series,
  required SubtitleSyncMemory memory,
}) {
  if (subtitleMatchesRelease(subtitle, release: release)) {
    return _ReleaseFit.release;
  }
  final group = subtitle.group;
  if (group != null &&
      (memory.speedFor(series: series, group: group) != null ||
          memory.shiftSecondsFor(
                series: series,
                group: group,
                release: release,
              ) !=
              0)) {
    return _ReleaseFit.adjusted;
  }
  return _ReleaseFit.offered;
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
/// The order the groups and their options come out in is the order
/// [sources] arrived in, so the ranking is [subtitlesByRelease]'s to do
/// first.
///
/// [release] is the name the player knows the video by, and every option
/// is asked whether the addon says it was cut for it
/// ([subtitleMatchesRelease]); null -- an offline play, a torrent nothing
/// has named the file of -- means nobody is marked, which is what knowing
/// nothing has to look like.
List<SubtitleLanguageGroup> groupSubtitlesByLanguage(
  Iterable<SubtitleSource> sources, {
  String Function(String manifestUrl)? addonName,
  String? release,
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
        matchesRelease: subtitleMatchesRelease(
          source.subtitle,
          release: release,
        ),
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
          matchesRelease: option.matchesRelease,
        )
      else
        option,
  ];
}
