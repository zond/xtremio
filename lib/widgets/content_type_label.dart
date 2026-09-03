import 'package:flutter/widgets.dart';

/// Display names for stremio-core content types (`movie`, `series`, ...):
/// the plural the official clients use, or the type capitalised when it is
/// one this client does not know.
String contentTypeLabel(String type) => switch (type) {
  'movie' => 'Movies',
  'series' => 'Series',
  'channel' => 'Channels',
  'tv' => 'TV',
  'music' => 'Music',
  'book' => 'Books',
  'game' => 'Games',
  'podcast' => 'Podcasts',
  _ => capitalise(type),
};

/// `genre` -> `Genre`; empty strings stay empty.
///
/// The first *character* is upper-cased, not the first code unit: a type
/// this client does not know is a string from an addon's manifest, and
/// `word[0]` on one that starts with an emoji is half a surrogate pair --
/// which Flutter's text layout refuses to draw at all.
String capitalise(String word) {
  if (word.isEmpty) return word;
  final first = word.characters.first;
  return '${first.toUpperCase()}${word.characters.skip(1).string}';
}
