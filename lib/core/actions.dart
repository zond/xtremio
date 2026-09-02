/// Typed builders for stremio-core actions, so screens never hand-write the
/// `{"action": ..., "args": ...}` JSON. Shapes follow
/// `stremio_core::runtime::msg::Action` (`#[serde(tag = "action",
/// content = "args")]`, nested the same way for sub-enums).
library;

import 'fields.dart';
import 'resource.dart';
import 'state/addon_descriptor.dart';
import 'state/installed_addons.dart';
import 'state/library.dart';
import 'state/profile.dart';

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

  // --- Ctx: account -------------------------------------------------------
  //
  // Every `Action::Ctx` goes out with `field: ctx`. With `field: null` the
  // engine would run it through every field's update as well (harmless here
  // but a broadcast), and with any other field it is silently ignored.

  static CoreAction _ctx(String action, [Object? args]) => CoreAction(
    field: CoreField.ctx,
    action: _tagged('Ctx', _tagged(action, args)),
  );

  /// Signs in with email and password (`AuthRequest::Login`; `facebook` is
  /// always false here). The profile, library and streams of this device are
  /// *replaced* by the account's on success. Outcome events:
  /// `UserAuthenticated`, then `UserAddonsLocked` / `UserLibraryMissing`, or
  /// `Error` with `source.event == UserAuthenticated`.
  static CoreAction login({required String email, required String password}) =>
      _ctx('Authenticate', {
        'type': 'Login',
        'email': email,
        'password': password,
        'facebook': false,
      });

  /// Creates an account (`AuthRequest::Register`). The API requires
  /// [consent] with `tos` and `privacy` true; `marketing` is optional.
  static CoreAction register({
    required String email,
    required String password,
    required GdprConsent consent,
  }) => _ctx('Authenticate', {
    'type': 'Register',
    'email': email,
    'password': password,
    'gdpr_consent': consent.toJson(),
  });

  /// Signs out: the profile, library and streams reset to their defaults
  /// (`UserLoggedOut`). Allowed while anonymous too.
  static CoreAction logout() => _ctx('Logout');

  /// Replaces `profile.addons` with the account's collection (and, logged
  /// out, upgrades the bundled official addons). Sets `addonsLocked` when
  /// the fetch fails. Events `AddonsPulledFromAPI`, `UserAddonsLocked`.
  static CoreAction pullAddonsFromAPI() => _ctx('PullAddonsFromAPI');

  /// Refreshes the user record of the signed-in account. The action's
  /// `args` object is required by the engine even when empty (an explicit
  /// `token` would fetch another user). An expired session (API code 1)
  /// logs the profile out.
  static CoreAction pullUserFromAPI() =>
      _ctx('PullUserFromAPI', <String, dynamic>{});

  /// Two-way library sync by modification time. Events
  /// `LibrarySyncWithAPIPlanned`, `LibraryItemsPushedToAPI`,
  /// `LibraryItemsPulledFromAPI`; `Error{Other code 1}` while logged out.
  static CoreAction syncLibraryWithAPI() => _ctx('SyncLibraryWithAPI');

  /// Asks the addons for new episodes of every library item that wants
  /// notifications. Always issues requests.
  static CoreAction pullNotifications() => _ctx('PullNotifications');

  // --- Ctx: library -------------------------------------------------------

  /// Adds a title to the library. [meta] is the raw `MetaItemPreview` /
  /// `MetaItem` JSON as received (the engine's action carries the whole
  /// item). Event `LibraryItemAdded`.
  static CoreAction addToLibrary(Map<String, dynamic> meta) =>
      _ctx('AddToLibrary', meta);

  /// Marks the item [id] removed (kept for sync; `Error{Other code 2}` when
  /// unknown). Event `LibraryItemRemoved`.
  static CoreAction removeFromLibrary(String id) =>
      _ctx('RemoveFromLibrary', id);

  /// Resets the item's progress to the start. Event `LibraryItemRewinded`.
  static CoreAction rewindLibraryItem(String id) =>
      _ctx('RewindLibraryItem', id);

  /// Flags the whole item watched or not (`is_watched` on the wire).
  static CoreAction libraryItemMarkAsWatched(
    String id, {
    required bool watched,
  }) => _ctx('LibraryItemMarkAsWatched', {'id': id, 'is_watched': watched});

  /// Mutes ([disabled] true, `state.noNotif`) or unmutes new-episode
  /// notifications for the item; muting dismisses its pending ones. A
  /// tuple on the wire.
  static CoreAction toggleLibraryItemNotifications(
    String id, {
    required bool disabled,
  }) => _ctx('ToggleLibraryItemNotifications', [id, disabled]);

  // --- Ctx: addons --------------------------------------------------------

  /// Installs [descriptor] (the fetched `remoteAddon` of `addon_details`,
  /// or a community catalog entry). Same-URL, different-content descriptors
  /// replace the installed one. `Error{Other}` code 7 while `addonsLocked`,
  /// 6 when `configurationRequired`, 3 when identical to an installed one.
  /// Event `AddonInstalled`.
  static CoreAction installAddon(AddonDescriptor descriptor) =>
      _ctx('InstallAddon', descriptor.json);

  /// Removes the installed [descriptor] and the streams saved through it.
  /// `Error{Other code 5}` for a protected addon. Event `AddonUninstalled`.
  static CoreAction uninstallAddon(AddonDescriptor descriptor) =>
      _ctx('UninstallAddon', descriptor.json);

  /// Replaces the installed copy with [descriptor] (same URL, different
  /// content; not protected, not `configurationRequired`). Event
  /// `AddonUpgraded`.
  static CoreAction upgradeAddon(AddonDescriptor descriptor) =>
      _ctx('UpgradeAddon', descriptor.json);

  // --- Ctx: settings ------------------------------------------------------

  /// Replaces `profile.settings` with [settings]: the *entire* map (the
  /// engine has no per-field defaults), normally
  /// `ProfileSettings.withValue(key, value)`. A map missing a field is
  /// rejected at dispatch with an "invalid action JSON" error. Events
  /// `SettingsUpdated`, `ProfileChanged`; the streaming server model
  /// reloads when `streamingServerUrl` changed.
  static CoreAction updateSettings(Map<String, dynamic> settings) =>
      _ctx('UpdateSettings', settings);

  // --- Library screen -----------------------------------------------------

  /// The library filtered by type, sorted, page 1 (or the page [request]
  /// names). Every entry of `library.selectable` carries the request to
  /// pass here.
  static CoreAction loadLibrary(LibraryRequest request) => CoreAction(
    field: CoreField.library,
    action: _load('LibraryWithFilters', {'request': request.toJson()}),
  );

  /// Extends `library.catalog` by the next 100 items (the list is
  /// cumulative, not appended). Only meaningful while
  /// `selectable.next_page` is set.
  static CoreAction loadLibraryNextPage() => CoreAction(
    field: CoreField.library,
    action: _tagged('LibraryWithFilters', _tagged('LoadNextPage')),
  );

  // --- Addon screens ------------------------------------------------------

  /// The profile's addons, optionally those serving one type.
  static CoreAction loadInstalledAddons(InstalledAddonsRequest request) =>
      CoreAction(
        field: CoreField.installedAddons,
        action: _load('InstalledAddonsWithFilters', {
          'request': request.toJson(),
        }),
      );

  /// One `addon_catalog` with its filters (the community list). With a null
  /// [request] the engine picks the first addon catalog of the
  /// highest-priority type; `remote_addons.selectable` carries explicit
  /// ones.
  static CoreAction loadRemoteAddons(ResourceRequest? request) => CoreAction(
    field: CoreField.remoteAddons,
    action: _load(
      'CatalogWithFilters',
      request == null ? null : {'request': request.toJson()},
    ),
  );

  /// Appends the next page of the addon catalog.
  static CoreAction loadRemoteAddonsNextPage() => CoreAction(
    field: CoreField.remoteAddons,
    action: _tagged('CatalogWithFilters', {'action': 'LoadNextPage'}),
  );

  /// Fetches the manifest at [transportUrl] (a `stremio://` URL is accepted
  /// and read as `https://`) into `addon_details.remoteAddon`, and looks up
  /// the installed copy as `localAddon`.
  static CoreAction loadAddonDetails(String transportUrl) => CoreAction(
    field: CoreField.addonDetails,
    action: _load('AddonDetails', {'transportUrl': transportUrl}),
  );

  /// Clears a model field back to its unloaded state.
  static CoreAction unload(CoreField field) =>
      CoreAction(field: field, action: _tagged('Unload'));
}
