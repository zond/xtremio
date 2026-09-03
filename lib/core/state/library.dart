/// Views over the `library` field (`LibraryWithFilters<NotRemovedFilter>`)
/// and over one `LibraryItem`, which `continue_watching_preview` and
/// `meta_details.libraryItem` share.
///
/// `LibraryWithFilters` has no `rename_all`, so its own keys are snake_case
/// (`next_page`), while the `LibraryItem`s inside are camelCase except for
/// `_id`, `_ctime`, `_mtime` and `state.video_id`.
library;

import '../well_formed_text.dart';

/// The lowercase wire names of `library_with_filters::Sort`.
abstract final class LibrarySort {
  static const String lastWatched = 'lastwatched';
  static const String name = 'name';
  static const String nameReverse = 'namereverse';
  static const String timesWatched = 'timeswatched';
  static const String watched = 'watched';
  static const String notWatched = 'notwatched';
}

/// `LibraryRequest`: what `Load LibraryWithFilters` takes. Every entry of
/// `library.selectable` carries the exact request to dispatch to select it.
final class LibraryRequest {
  const LibraryRequest({
    this.type,
    this.sort = LibrarySort.lastWatched,
    this.page = 1,
  });

  /// A meta type (`movie`, `series`, ...), or null for every type.
  final String? type;

  /// One of [LibrarySort].
  final String sort;

  /// 1-based. Pages are cumulative: page N is the first N × 100 items.
  final int page;

  factory LibraryRequest.fromJson(Map<String, dynamic> json) => LibraryRequest(
    type: json['type'] as String?,
    sort: json['sort'] as String? ?? LibrarySort.lastWatched,
    page: (json['page'] as num?)?.toInt() ?? 1,
  );

  Map<String, dynamic> toJson() => {'type': type, 'sort': sort, 'page': page};

  @override
  bool operator ==(Object other) =>
      other is LibraryRequest &&
      other.type == type &&
      other.sort == sort &&
      other.page == page;

  @override
  int get hashCode => Object.hash(type, sort, page);
}

/// View over one `LibraryItem` (a `continue_watching_preview` item has a
/// `notifications` count flattened in as well).
final class LibraryItemView {
  const LibraryItemView(this.json);

  final Map<String, dynamic> json;

  Map<String, dynamic> get _state =>
      json['state'] as Map<String, dynamic>? ?? const {};

  String get id => json['_id'] as String;
  String get type => json['type'] as String;
  String get name => wellFormedText(json['name'] as String?) ?? '';
  String? get poster => json['poster'] as String?;

  /// `poster` | `landscape` | `square`.
  String get posterShape => json['posterShape'] as String? ?? 'poster';

  /// Removed from the library (a played-but-never-added title is
  /// `removed: true, temp: true`).
  bool get removed => json['removed'] as bool? ?? false;

  bool get temp => json['temp'] as bool? ?? false;

  /// In the library proper (`NotRemovedFilter`).
  bool get isInLibrary => !removed;

  /// `_mtime`, when parseable.
  DateTime? get modifiedAt => _date(json['_mtime']);

  /// `state.lastWatched`, when set and parseable.
  DateTime? get lastWatched => _date(_state['lastWatched']);

  /// The video last played: an episode id (`tt1:2:3`) for series, the meta
  /// id for movies; null before anything was played.
  String? get videoId => _state['video_id'] as String?;

  /// Milliseconds into [videoId].
  int get timeOffset => (_state['timeOffset'] as num?)?.toInt() ?? 0;

  /// Milliseconds; 0 when the player never reported one.
  int get duration => (_state['duration'] as num?)?.toInt() ?? 0;

  /// Milliseconds watched across every video.
  int get overallTimeWatched =>
      (_state['overallTimeWatched'] as num?)?.toInt() ?? 0;

  /// Videos (or, for movies, plays) counted as watched.
  int get timesWatched => (_state['timesWatched'] as num?)?.toInt() ?? 0;

  /// `LibraryItem::watched`: anything was ever watched to completion.
  bool get isWatched => timesWatched > 0;

  /// Notifications for new episodes are muted.
  bool get notificationsDisabled => _state['noNotif'] as bool? ?? false;

  /// Watched fraction of the current video in `0..1`, or null when the
  /// duration is unknown (`LibraryItem::progress`).
  double? get progress {
    if (timeOffset <= 0 || duration <= 0) return null;
    return (timeOffset / duration).clamp(0.0, 1.0);
  }

  /// `LibraryItem::is_in_continue_watching`: not `other`, in the library or
  /// temporary, with progress.
  bool get isInContinueWatching =>
      type != 'other' && (!removed || temp) && timeOffset > 0;

  /// Unseen new episodes for this item (only `continue_watching_preview`
  /// carries the count; 0 elsewhere).
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

  static DateTime? _date(Object? json) =>
      json is String ? DateTime.tryParse(json)?.toUtc() : null;

  static List<LibraryItemView> listFromJson(Object? json) => [
    for (final item in (json as List<dynamic>? ?? const []))
      LibraryItemView(item as Map<String, dynamic>),
  ];
}

/// One entry of `library.selectable.types`: `null` is "all types".
final class LibraryTypeOption {
  const LibraryTypeOption({
    required this.type,
    required this.selected,
    required this.request,
  });

  final String? type;
  final bool selected;

  /// The request to dispatch (`Load LibraryWithFilters`) to select this.
  final LibraryRequest request;

  factory LibraryTypeOption.fromJson(Map<String, dynamic> json) =>
      LibraryTypeOption(
        type: json['type'] as String?,
        selected: json['selected'] as bool? ?? false,
        request: LibraryRequest.fromJson(
          json['request'] as Map<String, dynamic>,
        ),
      );
}

/// One entry of `library.selectable.sorts`.
final class LibrarySortOption {
  const LibrarySortOption({
    required this.sort,
    required this.selected,
    required this.request,
  });

  /// One of [LibrarySort].
  final String sort;
  final bool selected;
  final LibraryRequest request;

  factory LibrarySortOption.fromJson(Map<String, dynamic> json) =>
      LibrarySortOption(
        sort: json['sort'] as String,
        selected: json['selected'] as bool? ?? false,
        request: LibraryRequest.fromJson(
          json['request'] as Map<String, dynamic>,
        ),
      );
}

/// `library.selectable`: the types present in the library (`null` first,
/// then by the engine's type priorities), every sort, and the next page.
final class LibrarySelectable {
  const LibrarySelectable({
    required this.types,
    required this.sorts,
    required this.nextPage,
  });

  const LibrarySelectable.empty()
    : types = const [],
      sorts = const [],
      nextPage = null;

  final List<LibraryTypeOption> types;
  final List<LibrarySortOption> sorts;

  /// Request for the next page, when an item exists past the loaded ones
  /// (`next_page` on the wire).
  final LibraryRequest? nextPage;

  factory LibrarySelectable.fromJson(Map<String, dynamic> json) {
    final nextPage = json['next_page'] as Map<String, dynamic>?;
    return LibrarySelectable(
      types: [
        for (final type in (json['types'] as List<dynamic>? ?? const []))
          LibraryTypeOption.fromJson(type as Map<String, dynamic>),
      ],
      sorts: [
        for (final sort in (json['sorts'] as List<dynamic>? ?? const []))
          LibrarySortOption.fromJson(sort as Map<String, dynamic>),
      ],
      nextPage: nextPage == null
          ? null
          : LibraryRequest.fromJson(
              nextPage['request'] as Map<String, dynamic>,
            ),
    );
  }

  LibraryTypeOption? get selectedType =>
      types.where((type) => type.selected).firstOrNull;

  LibrarySortOption? get selectedSort =>
      sorts.where((sort) => sort.selected).firstOrNull;
}

/// View over the `library` field.
final class LibraryState {
  const LibraryState({
    required this.selected,
    required this.selectable,
    required this.items,
  });

  /// The loaded request, or null when the model is unloaded.
  final LibraryRequest? selected;

  final LibrarySelectable selectable;

  /// Every item of every loaded page, filtered and sorted by the engine.
  /// Cumulative: a `LoadNextPage` replaces this with a longer list.
  final List<LibraryItemView> items;

  factory LibraryState.fromJson(Map<String, dynamic> json) {
    final selected = json['selected'] as Map<String, dynamic>?;
    final selectable = json['selectable'] as Map<String, dynamic>?;
    return LibraryState(
      selected: selected == null
          ? null
          : LibraryRequest.fromJson(
              selected['request'] as Map<String, dynamic>,
            ),
      selectable: selectable == null
          ? const LibrarySelectable.empty()
          : LibrarySelectable.fromJson(selectable),
      items: LibraryItemView.listFromJson(json['catalog']),
    );
  }

  bool get isLoaded => selected != null;

  /// No item matches the loaded request.
  bool get isEmpty => items.isEmpty;

  /// A type filter is loaded (`selected.request.type != null`).
  bool get hasTypeFilter => selected?.type != null;

  /// The type filter matches nothing while the library still holds titles
  /// of other types: the engine recomputes `selectable.types` from the
  /// remaining items, so the `null` (All) entry stays on offer.
  bool get isFilteredEmpty => isEmpty && hasTypeFilter;

  /// Nothing is in the library at all (or the model is unloaded): with no
  /// type filter the catalog holds every item, so an empty one is the whole
  /// library.
  bool get isLibraryEmpty => isEmpty && !hasTypeFilter;

  LibraryRequest? get nextPage => selectable.nextPage;

  bool get hasNextPage => nextPage != null;
}
