import 'dart:async';

import 'package:xtremio/core/core.dart';

/// [DownloadsClient] for widget tests: an in-memory registry, a record of
/// every call, and a way to push progress by hand. No FFI, no torrents.
class FakeDownloadsClient implements DownloadsClient {
  FakeDownloadsClient({DownloadsRegistry? registry})
    : registry = registry ?? DownloadsRegistry.empty;

  /// What [list] answers, and what [add], [remove] and [emit] change.
  DownloadsRegistry registry;

  /// The server settings [setDirectory] answers with, `downloadsDir` laid
  /// over them.
  Map<String, dynamic> settings = const {};

  /// Every call made, in order.
  final List<DownloadRequest> added = [];
  final List<({String key, bool deleteFiles})> removed = [];
  final List<String?> directories = [];

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

  /// Thrown by the matching call when set, for the failure paths.
  Object? addError;
  Object? removeError;
  Object? listError;
  Object? setDirectoryError;

  bool disposed = false;

  final StreamController<DownloadsRegistry> _updates =
      StreamController<DownloadsRegistry>.broadcast();

  @override
  Stream<DownloadsRegistry> get updates => _updates.stream;

  /// Pushes a progress event carrying [update]'s entries, as the Rust
  /// ticker would, and folds it into [registry] so a later [list] agrees
  /// with what the listeners just saw.
  void emit(DownloadsRegistry update) {
    registry = registry.merge(update);
    _updates.add(update);
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
  Future<Map<String, dynamic>> setDirectory(String? path) async {
    directories.add(path);
    callLog?.add('downloads.setDirectory');
    final error = setDirectoryError;
    if (error != null) throw error;
    return settings = {...settings, 'downloadsDir': path};
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
