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

  /// Loads pages [start, end) of the board's catalogs.
  static CoreAction loadBoardRange(int start, int end) => CoreAction(
    field: CoreField.board,
    action: _tagged('CatalogsWithExtra', {
      'action': 'LoadRange',
      'args': {'start': start, 'end': end},
    }),
  );

  /// One catalog with its filters (the Discover screen).
  static CoreAction loadDiscover(ResourceRequest request) => CoreAction(
    field: CoreField.discover,
    action: _load('CatalogWithFilters', {'request': request.toJson()}),
  );

  /// Appends the next page of the Discover catalog.
  static CoreAction loadDiscoverNextPage() => CoreAction(
    field: CoreField.discover,
    action: _tagged('CatalogWithFilters', {'action': 'LoadNextPage'}),
  );

  /// Meta + streams for one item; [guessStream] lets the engine pick the
  /// stream to resume for series.
  static CoreAction loadMetaDetails({
    required String type,
    required String id,
    ResourcePath? streamPath,
    bool guessStream = true,
  }) => CoreAction(
    field: CoreField.metaDetails,
    action: _load('MetaDetails', {
      'metaPath': ResourcePath(resource: 'meta', type: type, id: id).toJson(),
      'streamPath': streamPath?.toJson(),
      'guessStream': guessStream,
    }),
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

  /// Clears a model field back to its unloaded state.
  static CoreAction unload(CoreField field) =>
      CoreAction(field: field, action: _tagged('Unload'));
}
