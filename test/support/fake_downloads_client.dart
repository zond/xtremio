import 'dart:async';

import 'package:xtremio/core/core.dart';

/// [DownloadsClient] for widget tests: an in-memory registry, a record of
/// every call, and a way to push progress by hand. No FFI, no torrents.
class FakeDownloadsClient implements DownloadsClient {
  FakeDownloadsClient({DownloadsRegistry? registry})
    : registry = registry ?? DownloadsRegistry.empty;

  /// What [list] answers, and what [add], [remove] and [emit] change.
  DownloadsRegistry registry;

  /// Every call made, in order.
  final List<DownloadRequest> added = [];
  final List<({String key, bool deleteFiles})> removed = [];

  /// The keys [open] was called with, in order.
  final List<String> opens = [];

  /// The embedded server [open]'s URLs are built on, as the Rust side
  /// builds them from the running server's base URL.
  static const String baseUrl = 'http://127.0.0.1:11470/';

  /// When set, every call also appends its name here: a log shared with the
  /// other fakes, for tests about the order of calls across them.
  List<String>? callLog;

  /// Answers [add] instead of the default (which accepts, and records a
  /// queued entry built from the request).
  DownloadAddResult Function(DownloadRequest request)? onAdd;

  /// Answers [remove] instead of the default (which forgets the entry and
  /// reports that as a pin dropped). Set it for the outcome the default
  /// cannot reach: `removed: true, unpinned: false`, one torrent under two
  /// metas, where the row goes and the file stays. The entry is forgotten
  /// only when the answer says [DownloadRemoveResult.removed].
  DownloadRemoveResult Function(String key, bool deleteFiles)? onRemove;

  /// Answers [open] instead of the default (which answers a server URL for
  /// a complete entry and refuses with the reason the Rust side would give
  /// otherwise).
  DownloadOpenResult Function(String key)? onOpen;

  /// Holds [add] and [open] open until it completes -- the registry is a
  /// round trip over FFI, and what a caller does with the answer is what
  /// a test about a late answer is about.
  Future<void>? pending;

  /// Thrown by the matching call when set, for the failure paths.
  Object? addError;
  Object? openError;
  Object? removeError;
  Object? listError;

  bool disposed = false;

  final StreamController<DownloadsUpdate> _updates =
      StreamController<DownloadsUpdate>.broadcast();

  @override
  Stream<DownloadsUpdate> get updates => _updates.stream;

  /// Pushes the narrow rows the Rust ticker really sends -- `{"key",
  /// "downloaded","size","state","path","error","completedAt"}` -- and
  /// folds them into [registry] so a later [list] agrees with what the
  /// listeners just saw.
  void emitProgress(Iterable<Map<String, dynamic>> rows) {
    final update = DownloadsProgressUpdate([
      for (final row in rows) DownloadProgress(row),
    ]);
    registry = update.applyTo(registry);
    _updates.add(update);
  }

  /// Pushes a whole listing envelope, the other shape the feed can carry.
  void emit(DownloadsRegistry update) {
    registry = registry.merge(update);
    _updates.add(DownloadsListingUpdate(update));
  }

  /// The same for one entry.
  void emitEntry(Map<String, dynamic> entry) => emit(
    DownloadsRegistry(
      version: registry.version,
      items: {DownloadView(entry).key: DownloadView(entry)},
    ),
  );

  @override
  Future<DownloadAddResult> add(DownloadRequest request) async {
    added.add(request);
    callLog?.add('downloads.add');
    if (pending != null) await pending;
    final error = addError;
    if (error != null) throw error;
    final result = onAdd?.call(request) ?? _accept(request);
    final entry = result.entry;
    if (entry != null) {
      registry = registry.merge(
        DownloadsRegistry(version: registry.version, items: {entry.key: entry}),
      );
    }
    return result;
  }

  @override
  Future<DownloadRemoveResult> remove(
    String key, {
    bool deleteFiles = false,
  }) async {
    removed.add((key: key, deleteFiles: deleteFiles));
    callLog?.add('downloads.remove');
    final error = removeError;
    if (error != null) throw error;
    final items = {...registry.items};
    final had = items.containsKey(key);
    final result =
        onRemove?.call(key, deleteFiles) ??
        DownloadRemoveResult(
          removed: had,
          unpinned: had,
          deletedFiles: had && deleteFiles,
        );
    if (result.removed) items.remove(key);
    registry = DownloadsRegistry(version: registry.version, items: items);
    // As the real client does: a removal is the one change the Rust feed
    // never carries, so the client itself tells its listeners.
    if (result.removed && !_updates.isClosed) {
      _updates.add(DownloadsRemovalUpdate([key]));
    }
    return result;
  }

  @override
  Future<DownloadsRegistry> list() async {
    callLog?.add('downloads.list');
    final error = listError;
    if (error != null) throw error;
    return registry;
  }

  @override
  Future<DownloadOpenResult> open(String key) async {
    opens.add(key);
    callLog?.add('downloads.open');
    if (pending != null) await pending;
    final error = openError;
    if (error != null) throw error;
    final result = onOpen?.call(key) ?? _openFromRegistry(key);
    if (result.ok) _stampPlayed(key);
    return result;
  }

  /// What the Rust side answers for an entry it has: the embedded server's
  /// media route for a finished download -- the pieces are only readable
  /// through it, and there is no file to open -- and the reason it cannot
  /// be played otherwise. A test that wants a server that is not running
  /// sets [onOpen].
  DownloadOpenResult _openFromRegistry(String key) {
    final view = registry[key];
    if (view == null) {
      return const DownloadOpenResult(
        ok: false,
        reason: DownloadOpenFailure.unknown,
      );
    }
    // A refusal carries no entry: `OpenOutcome::refused` leaves the field
    // out, so the bridge never has one to read back.
    if (!view.isComplete) {
      return const DownloadOpenResult(
        ok: false,
        reason: DownloadOpenFailure.incomplete,
      );
    }
    return DownloadOpenResult(
      ok: true,
      url: '$baseUrl${view.infoHash}/${view.fileIdx}',
      entry: view,
    );
  }

  /// Stamps `lastPlayedAt`, as the registry does on an open it answered.
  void _stampPlayed(String key) {
    final view = registry[key];
    if (view == null) return;
    final entry = DownloadView({
      ...view.json,
      'lastPlayedAt': DateTime.now().toUtc().toIso8601String(),
    });
    registry = DownloadsRegistry(
      version: registry.version,
      items: {...registry.items, key: entry},
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _updates.close();
  }

  /// A pin the server took: a queued entry with what the request carried.
  DownloadAddResult _accept(DownloadRequest request) =>
      DownloadAddResult.fromJson({
        'ok': true,
        'key': request.key,
        'entry': {
          ...request.toJson(),
          'infoHash': request.stream.infoHash ?? '',
          'fileIdx': request.fileIdx ?? request.stream.fileIdx ?? 0,
          'announce': [
            for (final tracker
                in (request.stream.json['announce'] as List<dynamic>? ??
                    const []))
              if (tracker is String) tracker,
          ],
          'size': 0,
          'downloaded': 0,
          'state': 'queued',
          'error': null,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'completedAt': null,
          'lastPlayedAt': null,
        },
      });
}
