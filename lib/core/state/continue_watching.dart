/// View over one item of `continue_watching_preview` (a `LibraryItem` with a
/// `notifications` count flattened in). Note the engine's snake keys `_id`,
/// `_ctime`, `_mtime` and `state.video_id`; everything else is camelCase.
final class ContinueWatchingItem {
  const ContinueWatchingItem(this.json);

  final Map<String, dynamic> json;

  Map<String, dynamic> get _state =>
      json['state'] as Map<String, dynamic>? ?? const {};

  String get id => json['_id'] as String;
  String get type => json['type'] as String;
  String get name => json['name'] as String? ?? '';
  String? get poster => json['poster'] as String?;

  /// `poster` | `landscape` | `square`.
  String get posterShape => json['posterShape'] as String? ?? 'poster';

  /// The video last played: an episode id (`tt1:2:3`) for series, the meta
  /// id for movies; null before anything was played.
  String? get videoId => _state['video_id'] as String?;

  /// Milliseconds into [videoId].
  int get timeOffset => (_state['timeOffset'] as num?)?.toInt() ?? 0;

  /// Milliseconds; 0 when the player never reported one.
  int get duration => (_state['duration'] as num?)?.toInt() ?? 0;

  /// Watched fraction of the current video in `0..1`, or null when the
  /// duration is unknown (`LibraryItem::progress`).
  double? get progress {
    if (timeOffset <= 0 || duration <= 0) return null;
    return (timeOffset / duration).clamp(0.0, 1.0);
  }

  /// Unseen new episodes for this item.
  int get notifications => (json['notifications'] as num?)?.toInt() ?? 0;

  /// `S2E3` when [videoId] is an `<id>:<season>:<episode>` episode id of
  /// this item; empty for movies and unknown id schemes.
  String get seasonEpisodeLabel {
    final videoId = this.videoId;
    if (videoId == null || !videoId.startsWith('$id:')) return '';
    final parts = videoId.substring(id.length + 1).split(':');
    if (parts.length != 2) return '';
    final season = int.tryParse(parts[0]);
    final episode = int.tryParse(parts[1]);
    if (season == null || episode == null) return '';
    return 'S${season}E$episode';
  }
}

/// View over the `continue_watching_preview` field: library items with
/// progress (or new episodes), newest first, capped by the engine.
final class ContinueWatchingState {
  const ContinueWatchingState(this.items);

  final List<ContinueWatchingItem> items;

  factory ContinueWatchingState.fromJson(Map<String, dynamic> json) =>
      ContinueWatchingState([
        for (final item in (json['items'] as List<dynamic>? ?? const []))
          ContinueWatchingItem(item as Map<String, dynamic>),
      ]);

  bool get isEmpty => items.isEmpty;
}
