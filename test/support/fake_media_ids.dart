import 'dart:async';

import 'package:xtremio/core/core.dart';

/// [MediaIds] for widget tests: hands out `m1`, `m2`, ... per registration,
/// whatever its kind, and records what the screen asked. No FFI.
class FakeMediaIds implements MediaIds {
  /// Every registration, in order, as the source it named: a URL on the
  /// server as it was handed over, a Drive file as `xtremio-drive:<id>`, a
  /// path as a `file:` URI, a `content:` document as itself. The id of the
  /// n-th is `m<n>`.
  final List<Uri> registered = [];

  /// The name each registration was given, in the same order.
  final List<String?> names = [];

  /// Every id resolved, in order.
  final List<String> resolved = [];

  /// Every play recorded, in order.
  final List<({String id, String token, String buffer})> plays = [];

  /// Every buffer change, in order.
  final List<(String, String)> buffers = [];

  /// Every id published, in order, and the tokens handed out for them
  /// (`t1`, `t2`, ...).
  final List<String> published = [];

  /// Every token unpublished, in order.
  final List<String> unpublished = [];

  /// What every resolve answers when [refusal] is null: playable, read in
  /// process, unless a test says otherwise.
  MediaResolution resolution = const MediaResolution();

  /// What every resolve answers instead, when set: the server will not
  /// play it.
  MediaRefusal? refusal;

  /// What the next resolves answer, one each, before [refusal] and
  /// [resolution] take over: null is playable.
  final List<MediaRefusal?> nextRefusals = [];

  /// Whether every resolve answers that the server reads the stream only
  /// forward, over HTTP -- an origin that will not serve ranges -- with
  /// the URL it was registered by as the `/proxy` URL to hand mpv, as the
  /// server does.
  bool readsForward = false;

  /// When set, every resolve waits for it: a torrent whose metadata has
  /// not arrived.
  Future<void>? resolvePending;

  /// When set, every registration throws it: the server not running.
  Object? registerFailure;

  /// When set, [publish] throws it: the listener not running, an id let go.
  Object? publishFailure;

  /// The id the screen was handed for [source], or null if it never was.
  String? idFor(Uri source) {
    final index = registered.indexOf(source);
    return index < 0 ? null : 'm${index + 1}';
  }

  /// The URL mpv is handed for the stream registered from [source].
  Uri playedUrlFor(Uri source) => mediaIdUrl(idFor(source)!);

  String _register(Uri source, String? name) {
    final failure = registerFailure;
    if (failure != null) throw failure;
    registered.add(source);
    names.add(name);
    return 'm${registered.length}';
  }

  @override
  String register(Uri streamingUrl) => _register(streamingUrl, null);

  @override
  String registerDrive(String fileId, {String? name}) =>
      _register(Uri.parse('xtremio-drive:$fileId'), name);

  @override
  String registerLocalPath(String path, {String? name}) =>
      _register(Uri.file(path), name);

  @override
  Future<String> registerLocalContent(Uri contentUri, {String? name}) async =>
      _register(contentUri, name);

  @override
  Future<MediaResolution> resolve(String id) async {
    resolved.add(id);
    final pending = resolvePending;
    if (pending != null) await pending;
    final refused = nextRefusals.isNotEmpty
        ? nextRefusals.removeAt(0)
        : refusal;
    if (refused != null) return MediaResolution.refused(refused);
    if (readsForward) {
      final index = int.parse(id.substring(1)) - 1;
      return MediaResolution(inProcess: false, proxyUrl: registered[index]);
    }
    return resolution;
  }

  @override
  void setPlay(String id, {required String token, required String buffer}) =>
      plays.add((id: id, token: token, buffer: buffer));

  @override
  void setBuffer(String id, String buffer) => buffers.add((id, buffer));

  @override
  Future<String> publish(String id) async {
    final failure = publishFailure;
    if (failure != null) throw failure;
    published.add(id);
    return 't${published.length}';
  }

  @override
  Future<bool> unpublish(String token) async {
    unpublished.add(token);
    return true;
  }
}
