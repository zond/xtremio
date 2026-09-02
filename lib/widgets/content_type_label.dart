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
String capitalise(String word) =>
    word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}';
