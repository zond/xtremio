import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../src/rust/api/downloads.dart' as rust;
import '../src/rust/api/server.dart' as rust_server;
import 'state/download.dart';
import 'state/stream.dart';

/// What the app asks the Rust side to keep offline: the stream the user
/// picked, plus what a row and an offline Details need to render without a
/// network. It is what the stream picker already has in hand.
final class DownloadRequest {
  const DownloadRequest({
    required this.metaId,
    required this.videoId,
    required this.stream,
    this.type = '',
    this.name = '',
    this.poster,
    this.fileIdx,
    this.meta,
    this.streamRequest,
    this.metaRequest,
  });

  /// The request that would add [view] again: what a retry sends after a
  /// download stopped. Everything comes off the entry, the resolved
  /// [fileIdx] included, so a retry cannot land on a different file than
  /// the one already half on disk.
  factory DownloadRequest.fromView(DownloadView view) => DownloadRequest(
    metaId: view.metaId,
    videoId: view.videoId,
    stream: view.stream,
    type: view.type,
    name: view.name,
    poster: view.poster,
    fileIdx: view.fileIdx,
    meta: view.meta,
    streamRequest: view.streamRequest,
    metaRequest: view.metaRequest,
  );

  final String metaId;

  /// The video inside the meta; the meta id itself for a movie.
  final String videoId;

  /// The addon's stream. Must be a torrent — anything else is the one thing
  /// `downloads_add` refuses with an exception rather than a failure.
  final StreamInfo stream;

  /// stremio-core's meta type (`movie`, `series`, ...).
  final String type;

  /// What the row shows.
  final String name;
  final String? poster;

  /// Overrides the stream's own `fileIdx`, for a caller that resolved the
  /// episode's file itself. Left out, the server picks the file the stream
  /// would have played (the `fileMustInclude` match, else the largest media
  /// file), which is what the player's `-1` asks for too.
  final int? fileIdx;

  /// A `MetaItem` snapshot, so Details renders offline.
  final Map<String, dynamic>? meta;

  /// The addon requests the stream and the meta came from, kept for
  /// `Load Player`.
  final Map<String, dynamic>? streamRequest;
  final Map<String, dynamic>? metaRequest;

  /// The registry key this request will land under.
  String get key => DownloadView.keyFor(metaId, videoId);

  Map<String, dynamic> toJson() => {
    'metaId': metaId,
    'videoId': videoId,
    'type': type,
    'name': name,
    'poster': poster,
    'stream': stream.json,
    if (fileIdx != null) 'fileIdx': fileIdx,
    if (meta != null) 'meta': meta,
    if (streamRequest != null) 'streamRequest': streamRequest,
    if (metaRequest != null) 'metaRequest': metaRequest,
  };

  @override
  String toString() => 'DownloadRequest($key)';
}

/// Why a pin was refused (`error.kind`).
enum DownloadFailureKind {
  /// Less free space than the missing bytes plus the server's margin;
  /// [DownloadFailure.requiredBytes] and friends carry the numbers.
  insufficientSpace('insufficientSpace'),

  /// The torrent has no such file.
  fileNotFound('fileNotFound'),

  /// Nobody supplied the torrent's metadata in time, or the engine refused
  /// the magnet.
  magnetAdd('magnetAdd'),

  /// The torrent engine refused the pin itself.
  backend('backend'),

  /// Nothing to ask: the embedded server is not running.
  unavailable('unavailable'),

  /// A kind this build does not know (a newer core).
  unknown('');

  const DownloadFailureKind(this.wireName);

  final String wireName;

  static DownloadFailureKind parse(Object? value) => values.firstWhere(
    (kind) => kind != unknown && kind.wireName == value,
    orElse: () => unknown,
  );
}

/// A refused pin. A full disk is something to show, not an exception, so it
/// comes back as a value with the server's own client-safe sentence — which
/// never names a local path — and, where there are any, the numbers that
/// sentence was built from.
final class DownloadFailure {
  const DownloadFailure(this.json);

  final Map<String, dynamic> json;

  DownloadFailureKind get kind => DownloadFailureKind.parse(json['kind']);

  /// The sentence to show.
  String get message => json['message'] as String? ?? '';

  /// [DownloadFailureKind.insufficientSpace]: the bytes still to fetch, what
  /// the volume has, and the margin the server insists on keeping free.
  int? get requiredBytes => _int('required');
  int? get availableBytes => _int('available');
  int? get marginBytes => _int('margin');

  /// [DownloadFailureKind.fileNotFound]: what was asked for, and how many
  /// files the torrent has.
  int? get fileIdx => _int('fileIdx');
  int? get fileCount => _int('fileCount');

  int? _int(String key) => (json[key] as num?)?.toInt();

  @override
  String toString() => 'DownloadFailure(${kind.wireName}: $message)';
}

/// What [DownloadsClient.add] answers.
final class DownloadAddResult {
  const DownloadAddResult({required this.ok, this.key, this.entry, this.error});

  /// Whether the pin was taken.
  final bool ok;

  /// The registry key it went under, refused or not.
  final String? key;

  /// The entry as it now stands; null when the pin was refused.
  final DownloadView? entry;

  /// Why it was refused; null when it was not.
  final DownloadFailure? error;

  factory DownloadAddResult.fromJson(Map<String, dynamic> json) {
    final entry = json['entry'];
    final error = json['error'];
    return DownloadAddResult(
      ok: json['ok'] == true,
      key: json['key'] as String?,
      entry: entry is Map<String, dynamic> ? DownloadView(entry) : null,
      error: error is Map<String, dynamic> ? DownloadFailure(error) : null,
    );
  }

  @override
  String toString() =>
      ok ? 'DownloadAddResult(ok, $key)' : 'DownloadAddResult($error)';
}

/// Why a download could not be played off the device (`reason`).
enum DownloadOpenFailure {
  /// The registry has no such entry: it was removed while a screen still
  /// held the row.
  unknown('unknown'),

  /// The bytes are not all here yet.
  incomplete('incomplete'),

  /// Whole as far as the registry knows, but the file is not where it was
  /// left -- an unmounted downloads volume, or a deletion from outside the
  /// app.
  missing('missing');

  const DownloadOpenFailure(this.wireName);

  final String wireName;

  /// A reason this build does not know reads as [unknown], which is what a
  /// caller does with all of them anyway: say so and stream instead.
  static DownloadOpenFailure parse(Object? value) => values.firstWhere(
    (reason) => reason.wireName == value,
    orElse: () => unknown,
  );
}

/// What [DownloadsClient.open] answers: the file to play, or why there is
/// none. A download whose file went away is a sentence and a fallback to
/// streaming, not an exception.
final class DownloadOpenResult {
  const DownloadOpenResult({
    required this.ok,
    this.url,
    this.entry,
    this.reason,
  });

  /// Whether there is a file on this device to play.
  final bool ok;

  /// The `file://` URL for it; null when there is none.
  final String? url;

  /// The entry as it now stands, `lastPlayedAt` stamped; null when the open
  /// was refused.
  final DownloadView? entry;

  /// Why it was refused; null when it was not.
  final DownloadOpenFailure? reason;

  factory DownloadOpenResult.fromJson(Map<String, dynamic> json) {
    final entry = json['entry'];
    final ok = json['ok'] == true;
    return DownloadOpenResult(
      ok: ok,
      url: json['url'] as String?,
      entry: entry is Map<String, dynamic> ? DownloadView(entry) : null,
      reason: ok ? null : DownloadOpenFailure.parse(json['reason']),
    );
  }

  @override
  String toString() =>
      ok ? 'DownloadOpenResult(ok)' : 'DownloadOpenResult(${reason?.wireName})';
}

/// What [DownloadsClient.remove] answers: what actually happened, rather
/// than the flags echoed back.
final class DownloadRemoveResult {
  const DownloadRemoveResult({
    required this.removed,
    required this.unpinned,
    required this.deletedFiles,
  });

  /// Whether the registry had an entry to forget.
  final bool removed;

  /// Whether the server's pin went with it. False when another download
  /// names the same file — one torrent offered under two metas — in which
  /// case the pin, and the bytes, are still the other one's.
  final bool unpinned;

  /// Whether bytes actually left the disk.
  final bool deletedFiles;

  factory DownloadRemoveResult.fromJson(Map<String, dynamic> json) =>
      DownloadRemoveResult(
        removed: json['removed'] == true,
        unpinned: json['unpinned'] == true,
        deletedFiles: json['deletedFiles'] == true,
      );

  @override
  String toString() =>
      'DownloadRemoveResult(removed: $removed, unpinned: $unpinned, '
      'deletedFiles: $deletedFiles)';
}

/// The app's way to the offline downloads. Behind an interface so widget
/// tests substitute a fake through [DownloadsScope] instead of pinning
/// torrents.
abstract interface class DownloadsClient {
  /// Pins the request's stream and records it. A refused pin comes back as
  /// [DownloadAddResult.error]; only a stream that is not a torrent throws.
  ///
  /// The call blocks until the pin is taken, which for a magnet means
  /// waiting on its metadata.
  Future<DownloadAddResult> add(DownloadRequest request);

  /// Drops the download [key] (`"{metaId}:{videoId}"`), with [deleteFiles]
  /// the bytes too.
  Future<DownloadRemoveResult> remove(String key, {bool deleteFiles = false});

  /// Every download, live progress merged in. Answers what is on disk when
  /// the server cannot be asked, so the list still renders offline.
  Future<DownloadsRegistry> list();

  /// What to play the download [key] off the device with, and a note that
  /// it was played: a finished download whose file is really there answers
  /// its `file://` URL and takes a `lastPlayedAt` stamp. Anything else --
  /// no such entry, not finished, or the file gone with its volume --
  /// answers [DownloadOpenResult.reason] so the caller streams the title
  /// instead of opening a player on a dead URL.
  Future<DownloadOpenResult> open(String key);

  /// Points the downloads at [path], or back at the torrent cache with null.
  /// Answers the server's settings afterwards; throws on a path it refuses.
  Future<Map<String, dynamic>> setDirectory(String? path);

  /// Where the files are being put (`settings.downloadsDir`), or null when
  /// they live in the torrent cache with everything else. Throws when the
  /// server cannot be asked.
  Future<String?> directory();

  /// Progress, as it happens: each event carries only the entries that
  /// moved, so fold them into a [list] with [DownloadsRegistry.merge].
  /// Broadcast, and nothing is buffered for a late subscriber.
  Stream<DownloadsRegistry> get updates;

  /// Releases the progress subscription. The client is done afterwards.
  Future<void> dispose();
}

/// The generated FFI functions [RustDownloadsClient] stands on, as types, so
/// a test can hand it recorded answers instead of a running server.
typedef DownloadsAddFn = Future<String> Function({required String requestJson});
typedef DownloadsRemoveFn = Future<String> Function({
  required String key,
  required bool deleteFiles,
});
typedef DownloadsListFn = Future<String> Function();
typedef DownloadsOpenFn = Future<String> Function({required String key});
typedef DownloadsSetDirFn = Future<String> Function({String? path});

/// Reading the destination back is reading the server's settings, which is
/// `server_settings` — the same JSON `downloads_set_dir` answers with.
typedef DownloadsSettingsFn = Future<String> Function();
typedef DownloadsEventsFn = Stream<String> Function();

/// [DownloadsClient] over `rust/src/api/downloads.rs` — the same functions
/// the server's download routes run, over FFI, without the HTTP or the
/// bearer token those routes want. The app never speaks HTTP to the
/// embedded server.
///
/// The Rust side keeps a single event sink, so this opens the progress
/// stream once, on the first look at [updates], and everything after that
/// shares one broadcast.
class RustDownloadsClient implements DownloadsClient {
  RustDownloadsClient({
    this.addDownload = rust.downloadsAdd,
    this.removeDownload = rust.downloadsRemove,
    this.listDownloads = rust.downloadsList,
    this.openDownload = rust.downloadsOpen,
    this.setDownloadsDir = rust.downloadsSetDir,
    this.readSettings = rust_server.serverSettings,
    this.openEvents = rust.downloadsEvents,
  });

  final DownloadsAddFn addDownload;
  final DownloadsRemoveFn removeDownload;
  final DownloadsListFn listDownloads;
  final DownloadsOpenFn openDownload;
  final DownloadsSetDirFn setDownloadsDir;
  final DownloadsSettingsFn readSettings;
  final DownloadsEventsFn openEvents;

  StreamController<DownloadsRegistry>? _controller;
  StreamSubscription<String>? _events;
  bool _disposed = false;

  @override
  Future<DownloadAddResult> add(DownloadRequest request) async =>
      DownloadAddResult.fromJson(
        _object(await addDownload(requestJson: jsonEncode(request.toJson()))),
      );

  @override
  Future<DownloadRemoveResult> remove(
    String key, {
    bool deleteFiles = false,
  }) async => DownloadRemoveResult.fromJson(
    _object(await removeDownload(key: key, deleteFiles: deleteFiles)),
  );

  @override
  Future<DownloadsRegistry> list() async =>
      DownloadsRegistry.fromJson(_object(await listDownloads()));

  @override
  Future<DownloadOpenResult> open(String key) async =>
      DownloadOpenResult.fromJson(_object(await openDownload(key: key)));

  @override
  Future<Map<String, dynamic>> setDirectory(String? path) async =>
      _object(await setDownloadsDir(path: path));

  @override
  Future<String?> directory() async =>
      _object(await readSettings())['downloadsDir'] as String?;

  @override
  Stream<DownloadsRegistry> get updates {
    if (_disposed) return const Stream<DownloadsRegistry>.empty();
    final controller = _controller ??=
        StreamController<DownloadsRegistry>.broadcast();
    _events ??= openEvents().listen(
      (payload) {
        final update = _parse(payload);
        if (update != null) controller.add(update);
      },
      onError: controller.addError,
      onDone: () => _endFeed(controller),
    );
    return controller.stream;
  }

  /// The Rust side keeps one event sink, so a second client replaces it and
  /// ends this stream. Close the broadcast so listeners hear the feed is
  /// over instead of sitting on a dead one, and let go of both halves so a
  /// later look at [updates] opens a fresh stream rather than handing back
  /// the closed one.
  void _endFeed(StreamController<DownloadsRegistry> controller) {
    _events = null;
    if (identical(_controller, controller)) _controller = null;
    controller.close();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _events?.cancel();
    _events = null;
    await _controller?.close();
    _controller = null;
  }

  /// A payload this build cannot read is dropped, not thrown: a progress
  /// event is a nicety, and the next [list] is the truth anyway. What is
  /// logged is why it could not be read -- a `FormatException` quotes the
  /// text it choked on, and an event's contents are not for the log.
  static DownloadsRegistry? _parse(String payload) {
    try {
      return DownloadsRegistry.fromJson(_object(payload));
    } on Object catch (error) {
      if (kDebugMode) {
        final reason = error is FormatException ? error.message : error;
        debugPrint('unreadable downloads event: $reason');
      }
      return null;
    }
  }

  static Map<String, dynamic> _object(String json) =>
      jsonDecode(json) as Map<String, dynamic>;
}

/// Provides the [DownloadsClient] to the widget tree, the way
/// `PlaybackScope` provides an engine. There is no fallback on purpose: the
/// real client holds the one progress subscription the Rust side allows, so
/// it is built once, by whoever also disposes it, and never conjured out of
/// a `BuildContext`.
class DownloadsScope extends InheritedWidget {
  const DownloadsScope({super.key, required this.client, required super.child});

  final DownloadsClient client;

  static DownloadsClient of(BuildContext context) {
    final client = maybeOf(context);
    assert(client != null, 'No DownloadsScope above this widget');
    return client!;
  }

  static DownloadsClient? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DownloadsScope>()?.client;

  @override
  bool updateShouldNotify(DownloadsScope oldWidget) =>
      client != oldWidget.client;
}
