/// What a model answered when it was asked what a title is like, and where
/// that answer is kept.
///
/// "More like this" costs a call to somebody's API, and the same model
/// asked the same question twice agrees with itself about half the time
/// (`tool/recommendations/README.md`, the `consistent` column). Two things
/// follow. A row that changed every time a title was opened would be a row
/// nobody could point at, so **the first answer is the answer**: it is
/// written down under the title it was asked about and read back for the
/// life of the install. And because it is written down, what is stored is
/// the *model's* answer -- titles and years -- rather than the catalogue
/// items it resolved to: the resolution is a lookup against whatever the
/// catalogues hold now, it is cheap, and it is the half that is allowed to
/// change when a poster does.
///
/// Nothing here is a claim that a suggestion is real. A model invents
/// films -- one invented twenty out of seventy-one in the measurements --
/// and every stored row goes through the same guard on the way to the
/// screen (`resolveSuggestions`), so an invented title is stored, resolves
/// to nothing, and costs one search.
///
/// The one thing that is allowed to expire an answer is the *question*.
/// Every row carries the version of the wording it came from
/// ([similarQuestionVersion]) and a row from another version is read back
/// as nothing remembered, because "the first answer is the answer" is a
/// rule about a question and not about a title: without it, changing the
/// wording would change what only a fresh install ever sees.
library;

import 'package:flutter/foundation.dart';

/// The model asked when the viewer has not named another
/// (`AppPrefs.similarModel`).
///
/// `gemini-3.1-flash-lite` on the evidence in `tool/recommendations`, not
/// on taste: of everything that answers inside the five seconds a row can
/// wait, it had the best coverage of the researched keys (0.91), the most
/// self-consistent repeat runs, few invented titles, and judgement within
/// 0.06 of the best model available at any speed -- which takes 153
/// seconds and is therefore no use here.
///
/// It lives beside the preference rather than beside the provider because
/// it is the *default of a setting*, and because the model names rot:
/// prefer a `-latest` alias where a provider offers one, since an alias
/// rots more slowly than a version does.
const String defaultSimilarModel = 'gemini-3.1-flash-lite';

/// Which version of the question produced a stored answer.
///
/// The first answer is the answer for the life of the install, which is
/// what makes the row point-at-able and is also a trap: a change to the
/// wording is a change nobody who has already opened a title ever sees.
/// Version 1 is the first question that asks about television as well as
/// film; the film-only question that shipped before it wrote no stamp at
/// all, and an unstamped row reads back as 0 -- *not this version* --
/// which is exactly what it is.
///
/// **Change [askForSimilar] and change this.** It lives here rather than
/// beside the question for the reason [defaultSimilarModel] does: this is
/// the half of it the preferences file has to know about, and nothing in
/// `core/` may reach into `features/`.
const int similarQuestionVersion = 1;

/// Which catalogue a suggestion is to be looked for in.
///
/// A model asked for films like one film answers with television too, and
/// is right to: asked what is like *Wave Twisters* it named *Æon Flux*,
/// which is a series, and the app plays series. So the kind travels with
/// the suggestion rather than being taken from whatever the viewer is
/// looking at.
enum SuggestedKind {
  film('film', 'movie'),
  series('series', 'series');

  const SuggestedKind(this.stored, this.catalogType);

  /// The word written to the preferences file, and the one a model is
  /// understood to have used when it volunteers a kind.
  final String stored;

  /// The `type` in an addon's catalogue path (`/catalog/{type}/...`), which
  /// is stremio's own vocabulary and not this enum's.
  final String catalogType;

  /// [stored] read back, or what a model called it, or null for anything
  /// else -- including nothing at all, which is the ordinary case.
  static SuggestedKind? parse(Object? value) => switch (value) {
    'film' || 'movie' => SuggestedKind.film,
    'series' || 'tv' || 'show' || 'tv series' => SuggestedKind.series,
    _ => null,
  };
}

/// One thing a model named: a title, the year it puts on it, and why.
///
/// [year] is not decoration and it is not optional. Searching an invented
/// title does not fail -- it answers with a real, unrelated film, which is
/// how *The Otherside (2022)*, which does not exist, resolved happily to a
/// 2008 film and a 2013 one. The year is the only thing in the answer that
/// can tell those apart from a hit, so a suggestion that names no year is
/// not a suggestion this can use.
@immutable
final class SuggestedTitle {
  const SuggestedTitle({
    required this.title,
    required this.year,
    required this.why,
    this.kind,
  });

  /// The title as the model wrote it, un-normalised. Matching normalises
  /// both sides ([resolveSuggestions]); this is kept as it came so that a
  /// stored answer can be read by a person.
  final String title;

  /// The year the model put on it. Matched within a year either way,
  /// because release years genuinely differ by one between a festival and
  /// a country, and by more than one only when the answer is wrong.
  final int year;

  /// The model's own sentence about the connection, in a dozen words or
  /// so. Kept because a row of posters says nothing about why they are
  /// there, and because the reason is what a viewer judges the row by.
  final String why;

  /// Which catalogue to look in. The schema asks for it now, so an answer
  /// to the current question states one; null is what a word
  /// [SuggestedKind.parse] does not know reads back as, and what every row
  /// stored before the schema asked reads as -- see [resolveSuggestions]
  /// for what happens then.
  final SuggestedKind? kind;

  /// The row as it is written to the preferences file. The kind is written
  /// only when there is one, so a file someone reads does not claim the
  /// model said "film" when it said nothing.
  Map<String, Object> toJson() => {
    'title': title,
    'year': year,
    'why': why,
    'kind': ?kind?.stored,
  };

  /// One stored row, or null when it is not one this build can use: no
  /// title, no year, a value of the wrong type. A row that cannot be read
  /// is dropped, never a failed load -- the worst it costs is one model
  /// call the next time the title is opened.
  static SuggestedTitle? fromJson(Object? json) {
    if (json is! Map) return null;
    final title = json['title'];
    final year = json['year'];
    if (title is! String || title.trim().isEmpty) return null;
    if (year is! int) return null;
    final why = json['why'];
    return SuggestedTitle(
      title: title.trim(),
      year: year,
      why: why is String ? why.trim() : '',
      kind: SuggestedKind.parse(json['kind']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SuggestedTitle &&
      other.title == title &&
      other.year == year &&
      other.why == why &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(title, year, why, kind);

  @override
  String toString() => 'SuggestedTitle($title, $year, ${kind?.stored})';
}

/// Every answer that has been kept, most recently asked first.
@immutable
final class SimilarMemory {
  const SimilarMemory(this.entries);

  /// Nothing asked yet: a fresh install, and what an unreadable stored
  /// value reads as.
  static const SimilarMemory empty = SimilarMemory(<SimilarAnswer>[]);

  /// One per title asked about. The order is recency and nothing reads it
  /// as anything else, so [remembering] is free to move what it touches to
  /// the front.
  final List<SimilarAnswer> entries;

  /// How many titles are remembered. Ten suggestions each, a few hundred
  /// bytes a row: this is a couple of hundred kilobytes at the very most,
  /// against a preferences file that is otherwise a few kilobytes. What
  /// falls off the end is the title asked about longest ago, and all it
  /// costs is being asked again.
  static const int limit = 128;

  /// What was answered about [id] of [type], or null when nothing this
  /// build can use was.
  ///
  /// An empty list is a *value*: the model answered and nothing it named
  /// survived parsing. Asking again would cost a call to be told the same
  /// thing, so null and empty are kept apart here the way they are
  /// everywhere else in this file.
  ///
  /// An answer to an *older* question is null rather than a value, and
  /// that is the point of [similarQuestionVersion]. A viewer who opened a
  /// series while the question was film-only has ten films written down
  /// under it; without this they would keep that row for the life of the
  /// install, and the change would be one only new installs ever saw.
  List<SuggestedTitle>? forItem({required String type, required String id}) {
    for (final entry in entries) {
      if (entry.type == type && entry.id == id) {
        return entry.askedAs == similarQuestionVersion
            ? entry.suggestions
            : null;
      }
    }
    return null;
  }

  /// This memory with [suggestions] written in under [type] and [id],
  /// stamped with the question that produced them, moved to the front,
  /// and the oldest row dropped once [limit] is past.
  ///
  /// The row this replaces goes whatever it was stamped with, so a
  /// re-ask forced by [similarQuestionVersion] costs one call and then
  /// stops costing anything.
  SimilarMemory remembering({
    required String type,
    required String id,
    required List<SuggestedTitle> suggestions,
  }) {
    final kept = [
      for (final entry in entries)
        if (!(entry.type == type && entry.id == id)) entry,
    ];
    return SimilarMemory(
      [
        SimilarAnswer(
          type: type,
          id: id,
          suggestions: suggestions,
          askedAs: similarQuestionVersion,
        ),
        ...kept,
      ].take(limit).toList(growable: false),
    );
  }

  List<Map<String, Object>> toJson() => [
    for (final entry in entries) entry.toJson(),
  ];

  /// The stored value read back, dropping every row this build cannot
  /// read. A value that is not a list at all is [empty].
  static SimilarMemory fromJson(Object? json) {
    if (json is! List) return empty;
    final entries = <SimilarAnswer>[];
    for (final row in json) {
      final entry = SimilarAnswer.fromJson(row);
      if (entry != null) entries.add(entry);
    }
    return entries.isEmpty ? empty : SimilarMemory(entries);
  }

  @override
  bool operator ==(Object other) =>
      other is SimilarMemory && listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hashAll(entries);
}

/// What one title was answered with.
@immutable
final class SimilarAnswer {
  const SimilarAnswer({
    required this.type,
    required this.id,
    required this.suggestions,
    required this.askedAs,
  });

  /// The meta item's own `type` (`movie`, `series`), which is half the key
  /// because ids are only unique within one.
  final String type;

  /// The meta item's id -- the film that was asked about, not any of the
  /// films in the answer.
  final String id;

  /// What the model named, in the order it named them. Possibly empty; see
  /// [SimilarMemory.forItem].
  final List<SuggestedTitle> suggestions;

  /// Which question was asked to get these ([similarQuestionVersion]).
  ///
  /// Zero for a row written before there was a stamp, which is the
  /// film-only question and is not any version this build asks.
  final int askedAs;

  Map<String, Object> toJson() => {
    'type': type,
    'id': id,
    'asked': askedAs,
    'films': [for (final suggestion in suggestions) suggestion.toJson()],
  };

  /// One stored row, or null when it names no title or no id -- a row
  /// nothing could be looked up by.
  ///
  /// A row with no `asked`, or one whose `asked` is not a number, is
  /// version 0: an answer this build did not ask for. That is not a row
  /// to drop -- dropping it and re-asking look the same from here, and
  /// keeping it means [SimilarMemory.remembering] has something to
  /// replace rather than a duplicate to make.
  static SimilarAnswer? fromJson(Object? json) {
    if (json is! Map) return null;
    final type = json['type'];
    final id = json['id'];
    if (type is! String || id is! String) return null;
    final films = json['films'];
    final suggestions = <SuggestedTitle>[];
    if (films is List) {
      for (final film in films) {
        final suggestion = SuggestedTitle.fromJson(film);
        if (suggestion != null) suggestions.add(suggestion);
      }
    }
    final asked = json['asked'];
    return SimilarAnswer(
      type: type,
      id: id,
      suggestions: List.unmodifiable(suggestions),
      askedAs: asked is int ? asked : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SimilarAnswer &&
      other.type == type &&
      other.id == id &&
      other.askedAs == askedAs &&
      listEquals(other.suggestions, suggestions);

  @override
  int get hashCode =>
      Object.hash(type, id, askedAs, Object.hashAll(suggestions));
}
