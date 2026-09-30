import 'dart:async';

import 'package:xtremio/core/core.dart';

/// [MediaIds] for widget tests: hands out `m1`, `m2`, ... per registered
/// URL and records what the screen asked. No FFI.
class FakeMediaIds implements MediaIds {
  /// Every URL registered, in order; the id of the n-th is `m<n>`.
  final List<Uri> registered = [];

  /// Every id resolved, in order.
  final List<String> resolved = [];

  /// Every play recorded, in order.
  final List<({String id, String token, String buffer})> plays = [];

  /// Every buffer change, in order.
  final List<(String, String)> buffers = [];

  /// What every resolve answers: null (playable) unless a test says
  /// otherwise.
  MediaRefusal? refusal;

  /// When set, every resolve waits for it: a torrent whose metadata has
  /// not arrived.
  Future<void>? resolvePending;

  /// When set, [register] throws it: the server not running.
  Object? registerFailure;

  /// The id the screen was handed for [url], or null if it never was.
  String? idFor(Uri url) {
    final index = registered.indexOf(url);
    return index < 0 ? null : 'm${index + 1}';
  }

  /// The URL mpv is handed for the stream registered from [url].
  Uri playedUrlFor(Uri url) => mediaIdUrl(idFor(url)!);

  @override
  String register(Uri streamingUrl) {
    final failure = registerFailure;
    if (failure != null) throw failure;
    registered.add(streamingUrl);
    return 'm${registered.length}';
  }

  @override
  Future<MediaRefusal?> resolve(String id) async {
    resolved.add(id);
    final pending = resolvePending;
    if (pending != null) await pending;
    return refusal;
  }

  @override
  void setPlay(String id, {required String token, required String buffer}) =>
      plays.add((id: id, token: token, buffer: buffer));

  @override
  void setBuffer(String id, String buffer) => buffers.add((id, buffer));
}
