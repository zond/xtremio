/// Which subtitle the viewer picks, remembered so the next episode comes
/// up the way the last one was left.
///
/// Two questions, two shapes, and they are deliberately separate:
///
/// - **What this show was watched with.** One row per show, holding the
///   language and -- when the addon named one -- the release group of the
///   file that was picked, or the fact that subtitles were turned off. It
///   is what the auto-pick reads when the engine has no session
///   preference of its own, which is every fresh start.
/// - **Which languages this viewer picks at all.** A count per language,
///   with no show attached, so the menu can lift the two it is asked for
///   most to the top of forty rows. A show never watched has no row above
///   and still gets those two.
///
/// **A count is only ever moved by a pick made by hand.** The auto-pick
/// applying a remembered row must never write, or one choice becomes
/// twenty-two counts over a season and the pins ossify -- the same
/// discipline that makes a press on the timing panel the only writer of
/// `SubtitleSyncMemory`.
///
/// What is stored is what the menu prints: the language *label*
/// (`subtitleLanguageLabel`), so an addon answering `sv` and one
/// answering `swe` are one memory, and the stored word is the row the
/// viewer chose. The release group is `SubtitleInfo.releaseGroupKey`,
/// lower-cased, which is the only name an addon gives a file that means
/// the same thing on the next episode -- and it is absent on about six
/// files in ten, which is not a shortfall but the rule this store shares
/// with `SubtitleSyncMemory`: a key nobody can name is not remembered,
/// and the memory then says only the language.
library;

import 'package:flutter/foundation.dart';

/// The subtitle a show was last watched with, or that it was watched with
/// none.
///
/// [enabled] false is a *value*, not an absence: a viewer who turns
/// subtitles off on a show they watch undubbed has said something, and
/// without somewhere to say it every episode would push them back on.
@immutable
final class SubtitleShowPick {
  /// A language picked by hand, with the release group of the very file
  /// when the addon named one and [embedded] set when what was picked was
  /// a track inside the video rather than an addon's file.
  const SubtitleShowPick({
    required this.series,
    required String this.language,
    this.releaseGroup,
    this.embedded = false,
  }) : enabled = true;

  /// Subtitles turned off, on purpose, on this show.
  const SubtitleShowPick.off({required this.series})
    : enabled = false,
      language = null,
      releaseGroup = null,
      embedded = false;

  /// The show or film: the meta item's id and not the episode's, the same
  /// value `SubtitleSyncEntry.series` is keyed on, because a language is
  /// a choice about a programme rather than about one of its episodes.
  final String series;

  /// Whether subtitles were on at all.
  final bool enabled;

  /// The label the menu prints for the language picked (`Swedish`), and
  /// null when [enabled] is false.
  final String? language;

  /// The lower-cased release group of the file that was picked, when the
  /// addon named one. Null is the ordinary case -- six files in ten carry
  /// no group -- and means the next episode takes the head of the
  /// language, exactly as it would with nothing remembered.
  final String? releaseGroup;

  /// Whether the pick was a track already in the video. Those have no
  /// release group and no URL to carry to another episode; all this
  /// remembers is that the file's own track was preferred to a download,
  /// which is the same thing the session preference's `source` says.
  final bool embedded;

  /// The row as it is written to the preferences file: only what this
  /// pick actually knows, so a file someone reads says `off` where
  /// subtitles were turned off and names a group only where one was
  /// named.
  Map<String, Object> toJson() => {
    'series': series,
    if (!enabled) 'off': true,
    'language': ?language,
    'releaseGroup': ?releaseGroup,
    if (embedded) 'embedded': true,
  };

  /// One stored row, or null when it is not one this build can use: no
  /// series, or a row that is neither an off nor a language. Preferences
  /// are forgiving -- an unreadable row is dropped, never a failure to
  /// load.
  static SubtitleShowPick? fromJson(Object? json) {
    if (json is! Map) return null;
    final series = _token(json['series']);
    if (series == null) return null;
    if (json['off'] == true) return SubtitleShowPick.off(series: series);
    final language = _token(json['language']);
    if (language == null) return null;
    return SubtitleShowPick(
      series: series,
      language: language,
      releaseGroup: _token(json['releaseGroup'])?.toLowerCase(),
      embedded: json['embedded'] == true,
    );
  }

  static String? _token(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleShowPick &&
      other.series == series &&
      other.enabled == enabled &&
      other.language == language &&
      other.releaseGroup == releaseGroup &&
      other.embedded == embedded;

  @override
  int get hashCode => Object.hash(series, enabled, language, releaseGroup);
}

/// Every show whose subtitle choice is still remembered, and how often
/// each language has been picked.
@immutable
final class SubtitlePickMemory {
  const SubtitlePickMemory({required this.shows, required this.languages});

  /// Nothing picked yet: a fresh install, and what an unreadable stored
  /// value reads as.
  static const SubtitlePickMemory empty = SubtitlePickMemory(
    shows: <SubtitleShowPick>[],
    languages: <String, int>{},
  );

  /// Most recently picked first. The order *is* the recency, as it is in
  /// `SubtitleSyncMemory`: a stored time would be one more thing to keep
  /// honest for no more answer than the position gives.
  final List<SubtitleShowPick> shows;

  /// How many times each language label has been picked by hand, across
  /// every show. Unordered; [pinned] is what puts it in an order.
  final Map<String, int> languages;

  /// How many shows are remembered. The same bound as
  /// `SubtitleSyncMemory.limit`, for the same reason: what falls off is
  /// what was watched longest ago, which is the one thing about a choice
  /// that says it is unlikely to be wanted again.
  static const int showLimit = 64;

  /// How many languages the menu lifts to the top. Two, because that is
  /// what was asked for, and because a third pin is most of a list that
  /// was sorted for a reason.
  static const int pinCount = 2;

  /// How many picks a language needs before it is pinned. **A guess, not
  /// a measurement**: nothing here has measured what a viewer's second
  /// language costs them to find. It exists so one curious tap on Thai
  /// does not earn a permanent slot above the alphabet.
  static const int pinThreshold = 3;

  /// The total number of picks at which every count is halved. **Also a
  /// guess.** Halving on picks rather than on days is the point: a
  /// language a viewer speaks does not go stale while the app is closed,
  /// so nothing here decays with the clock the way `addon_health` does --
  /// what makes an old preference weak is newer preferences, and those
  /// arrive one pick at a time. Halving keeps the store small, keeps the
  /// arithmetic legible in a file a person may read, and lets a taste
  /// that changes be followed within a few dozen picks instead of never.
  static const int countCeiling = 256;

  /// What this [series] was last watched with, or null when it has never
  /// been -- which is also what an unnamed series (an offline file, a
  /// stream with no meta behind it) answers.
  SubtitleShowPick? forSeries(String? series) {
    if (series == null) return null;
    for (final pick in shows) {
      if (pick.series == series) return pick;
    }
    return null;
  }

  /// Which of the languages [offered] to lift to the top of the menu: at
  /// most [pinCount], most picked first, and only those picked at least
  /// [pinThreshold] times.
  ///
  /// **Only languages this episode really offers.** A pin is a row moved,
  /// never a row invented, so a language nothing answered with cannot be
  /// pinned -- which is the same rule that stops the auto-pick
  /// preselecting one.
  ///
  /// **[offered] is every language the sheet offers**, the tracks inside
  /// the video as well as the addons' answers: a pick of either raises
  /// the same count here (`subtitleLanguageLabel` is what both are stored
  /// as), so a ranking that left the file's own tracks out would call a
  /// language the commonest of what is on offer while a language picked
  /// three times as often sat in the section above it. A language named
  /// twice, because the file and an addon both have it, is one language
  /// and takes one slot; the first mention is the one that counts.
  ///
  /// [offered] is taken in the order the caller has it -- the menu's
  /// addon rows, then the file's own tracks -- and the sort is on (picks,
  /// that position) so ties come out in that order and two rebuilds of
  /// one menu never disagree -- `List.sort` is not stable, so the
  /// position is part of the key rather than left to it.
  List<String> pinned(Iterable<String> offered) {
    final candidates = <(int, int, String)>[];
    final seen = <String>{};
    var position = 0;
    for (final language in offered) {
      if (!seen.add(language)) continue;
      final picks = languages[language] ?? 0;
      if (picks >= pinThreshold) candidates.add((picks, position, language));
      position++;
    }
    candidates.sort((a, b) {
      final byPicks = b.$1.compareTo(a.$1);
      return byPicks != 0 ? byPicks : a.$2.compareTo(b.$2);
    });
    return [for (final candidate in candidates.take(pinCount)) candidate.$3];
  }

  /// This memory with [pick] written into it: the show's row replaced and
  /// moved to the front, and the language's count raised by one.
  ///
  /// An off row counts towards no language -- there is no language in it
  /// to count -- but it still takes the show's row, because "none here"
  /// is exactly what the next episode has to be told.
  SubtitlePickMemory remembering(SubtitleShowPick pick) {
    final kept = [
      for (final row in shows)
        if (row.series != pick.series) row,
    ];
    final updated = <SubtitleShowPick>[pick, ...kept];
    final language = pick.language;
    final counted = language == null
        ? languages
        : _counting(language, languages);
    final next = SubtitlePickMemory(
      shows: List.unmodifiable(
        updated.length <= showLimit ? updated : updated.sublist(0, showLimit),
      ),
      languages: Map.unmodifiable(counted),
    );
    return next == this ? this : next;
  }

  /// [languages] with one more pick of [language], halved all round once
  /// the total passes [countCeiling].
  ///
  /// Halving drops what reaches zero, which is what keeps the map small:
  /// a language tried once and never again leaves at the first halving,
  /// and one picked in earnest survives several.
  static Map<String, int> _counting(String language, Map<String, int> counts) {
    final next = <String, int>{
      ...counts,
      language: (counts[language] ?? 0) + 1,
    };
    var total = 0;
    for (final count in next.values) {
      total += count;
    }
    if (total <= countCeiling) return next;
    return <String, int>{
      for (final MapEntry(key: name, value: count) in next.entries)
        if (count ~/ 2 > 0) name: count ~/ 2,
    };
  }

  /// What is written under the preferences' one key. The shows are a
  /// list, because their order is the recency; the counts are an object,
  /// because a language is a name and nothing about their order means
  /// anything.
  Map<String, Object> toJson() => {
    'shows': [for (final pick in shows) pick.toJson()],
    'languages': languages,
  };

  /// Reads the stored value, dropping any row or count this build cannot
  /// use and keeping at most [showLimit] shows.
  static SubtitlePickMemory fromJson(Object? json) {
    if (json is! Map) return empty;
    final shows = <SubtitleShowPick>[];
    final seen = <String>{};
    final rows = json['shows'];
    for (final row in rows is List ? rows : const []) {
      final pick = SubtitleShowPick.fromJson(row);
      // One row per show: a hand-edited file naming a series twice would
      // otherwise leave a row nothing can ever reach.
      if (pick != null && seen.add(pick.series)) shows.add(pick);
      if (shows.length == showLimit) break;
    }
    final languages = <String, int>{};
    final counts = json['languages'];
    if (counts is Map) {
      for (final MapEntry(:key, :value) in counts.entries) {
        // A count that is not a whole number above zero is not a count.
        if (key is String &&
            key.trim().isNotEmpty &&
            value is int &&
            value > 0) {
          languages[key] = value;
        }
      }
    }
    return shows.isEmpty && languages.isEmpty
        ? empty
        : SubtitlePickMemory(
            shows: List.unmodifiable(shows),
            languages: Map.unmodifiable(languages),
          );
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitlePickMemory &&
      listEquals(other.shows, shows) &&
      mapEquals(other.languages, languages);

  @override
  int get hashCode => Object.hash(Object.hashAll(shows), languages.length);
}
