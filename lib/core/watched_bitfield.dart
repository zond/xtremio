/// Which episodes of a series a library item says were watched.
///
/// A `LibraryItem`'s `state.watched` is stremio-core's `WatchedField`
/// (`stremio-watched-bitfield`, `watched_bitfield.rs`, in the pinned
/// stremio-core): `{anchorVideoId}:{anchorLength}:{base64(zlib(bits))}`, one
/// bit per video of the meta in stremio-core's order, least significant bit
/// first. The bits are positions, not ids, so they are read against the meta's
/// video list as it is now. The anchor is the last watched video when the field
/// was written, at index `anchorLength - 1` then. It is looked up in the list,
/// and every bit is shifted by how far it moved. An anchor the list no longer
/// has means nothing watched, as it does in stremio-core
/// (`construct_with_videos`).
///
/// A port of those two functions and nothing more; the tests hold it to
/// fields stremio-core wrote.
library;

import 'dart:convert';
import 'dart:io';

/// The ids in [videoIds] (already in stremio-core's order: see
/// [sortedVideos]) that [watched] marks, or an empty set for a field
/// this cannot read.
Set<String> watchedVideoIds(String? watched, List<String> videoIds) {
  if (watched == null || watched.isEmpty) return const {};
  // The id may itself hold colons, so the two numbers come off the end.
  final parts = watched.split(':');
  if (parts.length < 3) return const {};
  final packed = parts.removeLast();
  final anchorLength = int.tryParse(parts.removeLast());
  final anchor = parts.join(':');
  if (anchorLength == null) return const {};
  final List<int> bytes;
  try {
    bytes = zlib.decode(base64.decode(packed));
  } on Object {
    return const {};
  }
  final anchorIndex = videoIds.indexOf(anchor);
  if (anchorIndex < 0) return const {};
  final offset = anchorLength - anchorIndex - 1;
  bool bit(int i) {
    if (i < 0) return false;
    final index = i ~/ 8;
    return index < bytes.length && (bytes[index] >> (i % 8)) & 1 != 0;
  }

  return {
    for (var i = 0; i < videoIds.length; i++)
      if (bit(i + offset)) videoIds[i],
  };
}

/// One video of a meta, as much of it as the order needs.
typedef MetaVideo = ({
  String id,
  int? season,
  int? episode,
  DateTime? released,
});

/// [videos] in stremio-core's order (`LibraryItemState::watched_bitfield`):
/// by season, then episode, then release, a missing one before every
/// present one.
List<MetaVideo> sortedVideos(Iterable<MetaVideo> videos) {
  int nullsFirst<T>(T? a, T? b, int Function(T, T) compare) {
    if (a == null) return b == null ? 0 : -1;
    if (b == null) return 1;
    return compare(a, b);
  }

  int byInt(int a, int b) => a.compareTo(b);
  int byTime(DateTime a, DateTime b) => a.compareTo(b);

  final list = [...videos];
  // A stable sort, as Rust's `sorted_by` is.
  final indexed = list.indexed.toList()
    ..sort((x, y) {
      final a = x.$2;
      final b = y.$2;
      var order = nullsFirst(a.season, b.season, byInt);
      if (order == 0) order = nullsFirst(a.episode, b.episode, byInt);
      if (order == 0) order = nullsFirst(a.released, b.released, byTime);
      return order == 0 ? x.$1.compareTo(y.$1) : order;
    });
  return [for (final (_, video) in indexed) video];
}
