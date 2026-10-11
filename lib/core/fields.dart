/// The fields of the Rust `XtremioModel`, as named on the wire
/// (`snake_case`, e.g. in `NewState` events and `core_get_state`).
enum CoreField {
  ctx('ctx'),
  continueWatchingPreview('continue_watching_preview'),
  board('board'),
  search('search'),
  discover('discover'),
  metaDetails('meta_details'),
  streamingServer('streaming_server'),
  player('player'),
  library('library'),
  installedAddons('installed_addons'),
  remoteAddons('remote_addons'),
  addonDetails('addon_details'),

  /// Not a model field: the whole library bucket, removed and temporary
  /// items too, which `ctx` holds and does not serialize (`LIBRARY_ITEMS`
  /// in `rust/src/core.rs`). No `NewState` names it; it changes when the
  /// library does, which is a change to `ctx`, so a `NewState` naming
  /// `ctx` touches it too ([ridesOn]).
  libraryItems('library_items');

  const CoreField(this.wireName);

  /// The `snake_case` name stremio-core uses for this field.
  final String wireName;

  /// The model field whose `NewState` says this one changed: itself, but
  /// for [libraryItems], which is part of `ctx`.
  CoreField get ridesOn => this == libraryItems ? ctx : this;

  static final Map<String, CoreField> _byWireName = {
    for (final field in values) field.wireName: field,
  };

  /// Looks a field up by wire name; null for fields this client does not
  /// know (e.g. after a Rust-side model gains a field).
  static CoreField? fromWireName(String name) => _byWireName[name];
}
