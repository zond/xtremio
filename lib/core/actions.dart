/// Typed builders for stremio-core actions, so screens never hand-write the
/// `{"action": ..., "args": ...}` JSON. Shapes follow
/// `stremio_core::runtime::msg::Action` (`#[serde(tag = "action",
/// content = "args")]`, nested the same way for sub-enums).
library;

import 'fields.dart';
import 'resource.dart';

/// An action plus the model field it targets (null = the whole model, which
/// stremio-core routes to `Ctx` and every field).
final class CoreAction {
  const CoreAction({required this.field, required this.action});

  final CoreField? field;
  final Map<String, dynamic> action;

  /// The envelope `core_dispatch` expects.
  Map<String, dynamic> toJson() => {'field': field?.wireName, 'action': action};
}

Map<String, dynamic> _tagged(String action, [Object? args]) => {
  'action': action,
  'args': ?args,
};

Map<String, dynamic> _load(String model, Object? args) =>
    _tagged('Load', {'model': model, 'args': args});

/// Builders for the actions the app dispatches.
abstract final class CoreActions {
  /// Home board: every catalog of every installed addon.
  static CoreAction loadBoard({
    String? type,
    List<ExtraValue> extra = const [],
  }) => CoreAction(
    field: CoreField.board,
    action: _load('CatalogsWithExtra', {
      'type': type,
      'extra': [for (final value in extra) value.toJson()],
    }),
  );

  /// Fetches the first page of the board catalogs at indices
  /// `start..=end`. The end is inclusive (the engine checks
  /// `start <= index && index <= end`); already-loaded catalogs are kept,
  /// so widening the range is idempotent.
  static CoreAction loadBoardRange(int start, int end) =>
      _catalogsWithExtraRange(CoreField.board, start, end);

  /// Search: every catalog whose manifest supports the `search` extra. Each
  /// Load also pushes [query] to the profile's search history, so callers
  /// debounce.
  static CoreAction loadSearch(String query) => CoreAction(
    field: CoreField.search,
    action: _load('CatalogsWithExtra', {
      'type': null,
      'extra': [ExtraValue('search', query).toJson()],
    }),
  );

  /// Fetches the search catalogs at indices `start..=end` (inclusive end,
  /// as [loadBoardRange]).
  static CoreAction loadSearchRange(int start, int end) =>
      _catalogsWithExtraRange(CoreField.search, start, end);

  static CoreAction _catalogsWithExtraRange(
    CoreField field,
    int start,
    int end,
  ) => CoreAction(
    field: field,
    action: _tagged('CatalogsWithExtra', {
      'action': 'LoadRange',
      'args': {'start': start, 'end': end},
    }),
  );

  /// The Discover screen with no catalog chosen: the engine picks the first
  /// catalog of the highest-priority type (movie, then series, ...) across
  /// the installed addons.
  static CoreAction loadDiscoverDefault() => CoreAction(
    field: CoreField.discover,
    action: _load('CatalogWithFilters', null),
  );

  /// One catalog with its filters (the Discover screen). Every entry of
  /// `discover.selectable` carries the exact request to pass here.
  static CoreAction loadDiscover(ResourceRequest request) => CoreAction(
    field: CoreField.discover,
    action: _load('CatalogWithFilters', {'request': request.toJson()}),
  );

  /// Appends the next page of the Discover catalog.
  static CoreAction loadDiscoverNextPage() => CoreAction(
    field: CoreField.discover,
    action: _tagged('CatalogWithFilters', {'action': 'LoadNextPage'}),
  );

  /// Meta + streams for one item. With [videoId] the streams of that video
  /// (an episode, or the movie itself) are requested and the engine does not
  /// guess; otherwise [guessStream] lets it pick the stream to resume. An
  /// explicit [streamPath] overrides [videoId].
  static CoreAction loadMetaDetails({
    required String type,
    required String id,
    String? videoId,
    ResourcePath? streamPath,
    bool? guessStream,
  }) {
    final path =
        streamPath ??
        (videoId == null
            ? null
            : ResourcePath(resource: 'stream', type: type, id: videoId));
    return CoreAction(
      field: CoreField.metaDetails,
      action: _load('MetaDetails', {
        'metaPath': ResourcePath(resource: 'meta', type: type, id: id).toJson(),
        'streamPath': path?.toJson(),
        'guessStream': guessStream ?? path == null,
      }),
    );
  }

  /// Flags one video of the loaded meta item as (un)watched. [video] is the
  /// raw `videos[]` JSON as received: the engine's action carries the whole
  /// `Video`. Marking the video the library item is on advances it to the
  /// next episode.
  static CoreAction markVideoAsWatched(
    Map<String, dynamic> video, {
    required bool watched,
  }) => CoreAction(
    field: CoreField.metaDetails,
    action: _tagged(
      'MetaDetails',
      _tagged('MarkVideoAsWatched', [video, watched]),
    ),
  );

  /// Selects a stream for playback. [stream] is the raw stream JSON as it
  /// came out of `meta_details.streams`.
  static CoreAction loadPlayer({
    required Map<String, dynamic> stream,
    ResourceRequest? streamRequest,
    ResourceRequest? metaRequest,
    ResourcePath? subtitlesPath,
  }) => CoreAction(
    field: CoreField.player,
    action: _load('Player', {
      'stream': stream,
      'streamRequest': streamRequest?.toJson(),
      'metaRequest': metaRequest?.toJson(),
      'subtitlesPath': subtitlesPath?.toJson(),
    }),
  );

  static CoreAction _player(String action, [Object? args]) => CoreAction(
    field: CoreField.player,
    action: _tagged('Player', _tagged(action, args)),
  );

  /// Regular playback progress (milliseconds); monotonic between seeks.
  static CoreAction playerTimeChanged({
    required int time,
    required int duration,
    required String device,
  }) => _player('TimeChanged', {
    'time': time,
    'duration': duration,
    'device': device,
  });

  /// A user-initiated seek (milliseconds).
  static CoreAction playerSeek({
    required int time,
    required int duration,
    required String device,
  }) => _player('Seek', {'time': time, 'duration': duration, 'device': device});

  static CoreAction playerPausedChanged(bool paused) =>
      _player('PausedChanged', {'paused': paused});

  static CoreAction playerEnded() => _player('Ended');

  static CoreAction playerNextVideo() => _player('NextVideo');

  /// What the player learned about the file once it opened. The engine
  /// only asks subtitle addons once some parameter is known, so this is
  /// what triggers the subtitle request; [hash] and [size] are the
  /// OpenSubtitles hash and byte size when available.
  static CoreAction playerVideoParamsChanged({
    String? filename,
    String? hash,
    int? size,
  }) => _player('VideoParamsChanged', {
    'videoParams': {'hash': hash, 'size': size, 'filename': filename},
  });

  /// The user's subtitle choice for this Player session: on or off, and
  /// from which [source] (`embedded` / `external`) in which [language].
  static CoreAction playerSubtitlePreferenceChanged({
    required bool enabled,
    String? source,
    String? language,
  }) => _player('SubtitlePreferenceChanged', {
    'preference': {
      'enabled': enabled,
      'source': ?source,
      'language': ?language,
    },
  });

  /// Clears a model field back to its unloaded state.
  static CoreAction unload(CoreField field) =>
      CoreAction(field: field, action: _tagged('Unload'));
}
