/// A stored `LibraryItem`, as `library_items` serializes it, for the For you
/// tests: only what the row reads.
Map<String, dynamic> libraryItemJson(
  String id, {
  String type = 'movie',
  String? name,
  bool removed = false,
  bool temp = false,
  int timesWatched = 0,
  int flaggedWatched = 0,
  String? watched,
  String? lastWatched,
  String added = '2026-01-01T00:00:00Z',
  int timeOffset = 0,
}) => {
  '_id': id,
  'name': name ?? 'Title $id',
  'type': type,
  'poster': null,
  'posterShape': 'poster',
  'removed': removed,
  'temp': temp,
  '_ctime': added,
  '_mtime': lastWatched ?? added,
  'state': {
    'lastWatched': lastWatched,
    'timeWatched': 0,
    'timeOffset': timeOffset,
    'overallTimeWatched': 0,
    'timesWatched': timesWatched,
    'flaggedWatched': flaggedWatched,
    'duration': 0,
    'video_id': null,
    'watched': watched,
    'noNotif': false,
  },
  'behaviorHints': <String, dynamic>{},
};

/// The `library_items` state holding [items].
Map<String, dynamic> libraryItemsState(List<Map<String, dynamic>> items) => {
  'items': items,
};
