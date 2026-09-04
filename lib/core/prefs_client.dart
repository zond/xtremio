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

  /// The `streamsSectioned` key: whether the Details screen lists every
  /// addon's streams together, cut into a collapsible section per
  /// resolution, instead of one section per addon. True — sectioned — is
  /// the default: a fresh install has never chosen, and a fresh install is
  /// what this flag now defaults to showing.
  ///
  /// This used to be named `streamsFlat`, back when grouped by addon was
  /// the default and this flag meant "cut across every addon instead"; the
  /// stored key changed with the rename so the default's own meaning could
  /// change without also flipping what an old install's saved `false`
  /// meant. [load] still reads that older key as a fallback so nobody's
  /// choice is lost by the rename — see there.
  static const String streamsSectionedKey = 'streamsSectioned';

  /// The boolean an install from before the rename may still have under
  /// its old name, `streamsFlat`. [load] reads it only when
  /// [streamsSectionedKey] itself is unset, and nothing here ever writes
  /// to it again — the first toggle after an upgrade moves the choice to
  /// the new key and the old one is left stale.
  static const String legacyStreamsFlatKey = 'streamsFlat';

  /// The `streamsOrder` key: what order the streams inside one resolution
  /// section of that list are in (see [StreamOrder]). Global for the same
  /// reason [streamsSectionedKey] is — an order chosen on one title is the
  /// order the next title comes up in.
  static const String streamsOrderKey = 'streamsOrder';

  /// The `openStreamSections` key: which resolution sections of the
  /// sectioned sources list are expanded, as a list of each section's
  /// stored label (a resolution's own [StreamResolution.label], or
  /// `'unknown'` for the section nothing could be read a resolution from —
  /// see `_sectionStorageLabel` in `meta_details_screen.dart`). Global and
  /// sticky the same way the layout and the order are: a section opened on
  /// one title is open on the next, and on the next restart.
  ///
  /// Every section starts collapsed until the viewer opens one — an empty
  /// list is a real, deliberately-chosen value ("collapse everything"),
  /// not "nothing chosen yet", so [load] keeps that apart from a missing
  /// key the same way it does for [streamsSectionedKey]. See
  /// [openStreamSections].
  static const String openStreamSectionsKey = 'openStreamSections';

  /// The `bufferAhead` key: how far ahead playback buffers by default (see
  /// [BufferAhead]). The player takes this unless the viewer overrides it
  /// for the playback on screen.
  static const String bufferAheadKey = 'bufferAhead';

  bool _streamsSectioned = true;

  bool get streamsSectioned => _streamsSectioned;

  StreamOrder _streamsOrder = StreamOrder.peersPerSize;

  StreamOrder get streamsOrder => _streamsOrder;

  /// The stored labels of the resolution sections currently expanded, or
  /// null when nothing has ever been chosen — a fresh install, or a load
  /// that has not run yet. The sources list also draws null and an empty
  /// set the same way (every section collapsed), but the two are not the
  /// same stored value: once a viewer has collapsed everything on purpose,
  /// that empty set has to keep reading back as "on purpose", including
  /// across a restart, never fall through to some other default.
  Set<String>? get openStreamSections => _openStreamSections;
  Set<String>? _openStreamSections;

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
    final sectioned = stored[streamsSectionedKey];
    if (sectioned is bool) {
      if (sectioned != _streamsSectioned) {
        _streamsSectioned = sectioned;
        changed = true;
      }
    } else {
      // No choice under the current name: fall back to the name an older
      // install may have written under, where false meant grouped and
      // true meant this same sectioned layout, just called "flat". Read
      // once, as a migration, and never written back here.
      final legacy = stored[legacyStreamsFlatKey];
      if (legacy is bool && legacy != _streamsSectioned) {
        _streamsSectioned = legacy;
        changed = true;
      }
    }
    // An unparseable value -- a name a newer build wrote, a number -- reads
    // as "not set", which is the default, not a failure.
    final order = StreamOrder.parse(stored[streamsOrderKey]);
    if (order != null && order != _streamsOrder) {
      _streamsOrder = order;
      changed = true;
    }
    final openSections = stored[openStreamSectionsKey];
    if (openSections is List) {
      final parsed = <String>{
        for (final entry in openSections)
          if (entry is String) entry,
      };
      if (!setEquals(parsed, _openStreamSections)) {
        _openStreamSections = parsed;
        changed = true;
      }
    }
    final buffer = BufferAhead.parse(stored[bufferAheadKey]);
    if (buffer != null && buffer != _bufferAhead) {
      _bufferAhead = buffer;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> setStreamsSectioned(bool value) async {
    if (_streamsSectioned == value) return;
    _streamsSectioned = value;
    notifyListeners();
    await _write(streamsSectionedKey, value);
  }

  Future<void> setStreamsOrder(StreamOrder value) async {
    if (_streamsOrder == value) return;
    _streamsOrder = value;
    notifyListeners();
    await _write(streamsOrderKey, value.stored);
  }

  Future<void> setOpenStreamSections(Set<String> value) async {
    if (setEquals(_openStreamSections, value)) return;
    _openStreamSections = value;
    notifyListeners();
    await _write(openStreamSectionsKey, value.toList());
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
