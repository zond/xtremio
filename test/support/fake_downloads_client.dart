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

  /// The keys [open] was called with, in order.
  final List<String> opens = [];

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

  /// Answers [open] instead of the default (which plays the entry's own
  /// `path` when it is complete, and refuses with the reason the Rust side
  /// would give otherwise).
  DownloadOpenResult Function(String key)? onOpen;

  /// Thrown by the matching call when set, for the failure paths.
  Object? addError;
  Object? openError;
  Object? removeError;
  Object? listError;
  Object? setDirectoryError;
  Object? directoryError;

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
  Future<DownloadOpenResult> open(String key) async {
    opens.add(key);
    callLog?.add('downloads.open');
    final error = openError;
    if (error != null) throw error;
    final result = onOpen?.call(key) ?? _openFromRegistry(key);
    if (result.ok) _stampPlayed(key);
    return result;
  }

  /// What the Rust side answers for an entry it has: the file the registry
  /// names when the download is finished and names one, and the reason it
  /// cannot be played otherwise. A path is taken at its word here -- a fake
  /// registry names files that were never written -- so a test that wants
  /// the vanished-file path sets [onOpen].
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
    final path = view.path;
    if (path == null) {
      return const DownloadOpenResult(
        ok: false,
        reason: DownloadOpenFailure.missing,
      );
    }
    return DownloadOpenResult(
      ok: true,
      url: Uri.file(path).toString(),
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
  Future<Map<String, dynamic>> setDirectory(String? path) async {
    directories.add(path);
    callLog?.add('downloads.setDirectory');
    final error = setDirectoryError;
    if (error != null) throw error;
    return settings = {...settings, 'downloadsDir': path};
  }

  @override
  Future<String?> directory() async {
    callLog?.add('downloads.directory');
    final error = directoryError;
    if (error != null) throw error;
    return settings['downloadsDir'] as String?;
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
