import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../src/rust/api/prefs.dart' as rust;
import 'buffer_ahead.dart';
import 'stream_order.dart';

/// The app's own preferences, over the Rust side's small JSON file
/// (`rust/src/prefs.rs`, `<storage_dir>/xtremio_prefs.json`).
///
/// These are the *client's* choices — how a list is laid out, which view a
/// screen comes up in — and deliberately not stremio-core `Settings`
/// fields: that struct is the engine's, it is synced to the account, and
/// adding to it would mean forking the core. They are equally deliberately
/// not a Dart preferences package: the storage directory is already ours
/// and already writes atomically.
///
/// An interface so widget tests can hand [AppPrefs] a map instead of
/// reaching FFI, the way `DiagnosticsClient` works for Diagnostics.
abstract interface class PrefsClient {
  /// Every preference that has been set. An empty map means none has been —
  /// a missing, unreadable or non-object file all read that way, since a
  /// preference is a default the user changed.
  Future<Map<String, dynamic>> getAll();

  /// Stores [value] under [key], or removes the key when it is null. Every
  /// other key in the file survives, including one a newer build wrote.
  Future<void> set(String key, Object? value);
}

/// [PrefsClient] over FFI.
class RustPrefsClient implements PrefsClient {
  const RustPrefsClient();

  @override
  Future<Map<String, dynamic>> getAll() async {
    final decoded = jsonDecode(await rust.prefsGetAll());
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  @override
  Future<void> set(String key, Object? value) => rust.prefsSet(
    key: key,
    valueJson: value == null ? null : jsonEncode(value),
  );
}

/// The preferences the app holds in memory, read once at start-up and
/// written through on every change.
///
/// One of these for the whole app, handed down as a [PrefsScope], because a
/// preference is global: a layout chosen on one title is the layout the
/// next title comes up in. It is a [ChangeNotifier] so the screens that
/// read one rebuild when it changes.
///
/// [load] failing (nothing has pointed storage anywhere yet, no Rust
/// library under a test) leaves the defaults, and a failed write leaves the
/// value in memory: the choice holds for this run and simply does not
/// survive a restart, which is a better answer than a control that snaps
/// back under the user's finger.
class AppPrefs extends ChangeNotifier {
  AppPrefs({this.client});

  /// One that persists nothing, for a screen mounted with no [PrefsScope]
  /// above it (a widget test that does not care where the choice goes).
  AppPrefs.inMemory() : this();

  /// Where the values are read from and written to; null persists nothing.
  final PrefsClient? client;

  /// The `streamsFlat` key: whether the Details screen lists every addon's
  /// streams together, in a collapsible section per resolution, instead of
  /// a section per addon. False — grouped by addon, the engine's own order
  /// — is the default.
  static const String streamsFlatKey = 'streamsFlat';

  /// The `streamsOrder` key: what order the streams inside one resolution
  /// section of that list are in (see [StreamOrder]). Global for the same
  /// reason [streamsFlatKey] is — an order chosen on one title is the order
  /// the next title comes up in.
  static const String streamsOrderKey = 'streamsOrder';

  /// The `bufferAhead` key: how far ahead playback buffers by default (see
  /// [BufferAhead]). The player takes this unless the viewer overrides it
  /// for the playback on screen.
  static const String bufferAheadKey = 'bufferAhead';

  bool _streamsFlat = false;

  bool get streamsFlat => _streamsFlat;

  StreamOrder _streamsOrder = StreamOrder.peersPerSize;

  StreamOrder get streamsOrder => _streamsOrder;

  BufferAhead _bufferAhead = BufferAhead.normal;

  BufferAhead get bufferAhead => _bufferAhead;

  /// Reads every stored preference. Called once at start-up, before any
  /// screen that reads one can be on the stack, so the first list is
  /// already laid out the way it was left.
  Future<void> load() async {
    final client = this.client;
    if (client == null) return;
    final Map<String, dynamic> stored;
    try {
      stored = await client.getAll();
    } catch (error) {
      // Preferences are conveniences: a failure here is a run with the
      // defaults, never a failure to start.
      if (kDebugMode) debugPrint('preferences unavailable: $error');
      return;
    }
    var changed = false;
    final flat = stored[streamsFlatKey];
    if (flat is bool && flat != _streamsFlat) {
      _streamsFlat = flat;
      changed = true;
    }
    // An unparseable value -- a name a newer build wrote, a number -- reads
    // as "not set", which is the default, not a failure.
    final order = StreamOrder.parse(stored[streamsOrderKey]);
    if (order != null && order != _streamsOrder) {
      _streamsOrder = order;
      changed = true;
    }
    final buffer = BufferAhead.parse(stored[bufferAheadKey]);
    if (buffer != null && buffer != _bufferAhead) {
      _bufferAhead = buffer;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> setStreamsFlat(bool value) async {
    if (_streamsFlat == value) return;
    _streamsFlat = value;
    notifyListeners();
    await _write(streamsFlatKey, value);
  }

  Future<void> setStreamsOrder(StreamOrder value) async {
    if (_streamsOrder == value) return;
    _streamsOrder = value;
    notifyListeners();
    await _write(streamsOrderKey, value.stored);
  }

  Future<void> setBufferAhead(BufferAhead value) async {
    if (_bufferAhead == value) return;
    _bufferAhead = value;
    notifyListeners();
    await _write(bufferAheadKey, value.stored);
  }

  Future<void> _write(String key, Object? value) async {
    final client = this.client;
    if (client == null) return;
    try {
      await client.set(key, value);
    } catch (error) {
      if (kDebugMode) debugPrint('preference $key not stored: $error');
    }
  }
}

/// Hands [AppPrefs] down the tree. An [InheritedNotifier], so a screen that
/// reads a preference rebuilds when it is changed anywhere else.
class PrefsScope extends InheritedNotifier<AppPrefs> {
  const PrefsScope({super.key, required AppPrefs prefs, required super.child})
    : super(notifier: prefs);

  static AppPrefs of(BuildContext context) {
    final prefs = maybeOf(context);
    assert(prefs != null, 'No PrefsScope above this widget');
    return prefs!;
  }

  static AppPrefs? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PrefsScope>()?.notifier;
}
