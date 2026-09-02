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
  player('player');

  const CoreField(this.wireName);

  /// The `snake_case` name stremio-core uses for this field.
  final String wireName;

  static final Map<String, CoreField> _byWireName = {
    for (final field in values) field.wireName: field,
  };

  /// Looks a field up by wire name; null for fields this client does not
  /// know (e.g. after a Rust-side model gains a field).
  static CoreField? fromWireName(String name) => _byWireName[name];
}
