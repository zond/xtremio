import 'dart:convert';

import 'package:xtremio/core/core.dart';

/// A [PrefsClient] over a map, standing in for the Rust side's preferences
/// file. Everything a screen writes is readable here, and the same instance
/// handed to a second [AppPrefs] is what a fresh app start reads — which is
/// how a test tells "the choice stuck" from "the widget kept its state".
class FakePrefsClient implements PrefsClient {
  FakePrefsClient([Map<String, dynamic>? stored])
    : stored = {...?stored},
      failing = false;

  /// One that throws from both sides, for the "preferences unavailable"
  /// path: the app runs on the defaults rather than failing to start.
  FakePrefsClient.failing() : stored = {}, failing = true;

  /// What is "on disk". Written through [set], read by [getAll].
  final Map<String, dynamic> stored;

  final bool failing;

  /// Every key written, in order, so a test can see that a toggle wrote
  /// once rather than on every rebuild.
  final List<String> writes = [];

  @override
  Future<Map<String, dynamic>> getAll() async {
    if (failing) throw StateError('no storage directory');
    // Through JSON, like the real one: a value that could not cross the
    // FFI boundary fails here too.
    return jsonDecode(jsonEncode(stored)) as Map<String, dynamic>;
  }

  @override
  Future<void> set(String key, Object? value) async {
    if (failing) throw StateError('no storage directory');
    writes.add(key);
    if (value == null) {
      stored.remove(key);
    } else {
      stored[key] = jsonDecode(jsonEncode(value));
    }
  }
}
