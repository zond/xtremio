import 'stream.dart';

/// Views over one offline download and over the registry they live in:
/// `<storage_dir>/downloads.json`, which `rust/src/downloads.rs` owns and
/// `downloads_list`/`downloads_events` answer with, progress merged in from
/// the embedded server.
///
/// The wire shape is camelCase throughout and the raw map is kept, the way
/// every other view here keeps it: the `stream`, `meta`, `streamRequest` and
/// `metaRequest` it carries are handed straight back to `Load Player` and to
/// Details, so nothing is reshaped on the way through.

/// What a download is doing (`state`).
enum DownloadState {
  /// Pinned, but nothing is on disk yet: metadata still resolving, or the
  /// bytes already there still being hash-checked.
  queued('queued'),

  /// Bytes are arriving (or the file sits partly downloaded with nobody to
  /// get the rest from).
  downloading('downloading'),

  /// `downloaded == size`: playable off the file, with no connection.
  complete('complete'),

  /// The server reported a reason it is not progressing ([DownloadView.error]).
  error('error'),

  /// Reserved: the server has no pause for a pinned file yet.
  paused('paused'),

  /// Everything this row named is off the device: the server holds no pin
  /// for its pieces any more, so there is nothing here to read. Written
  /// once, by the boot reconciliation that found the root moved or
  /// reclaimed out from under it. Nothing fetches it again until the user
  /// asks -- which is the whole difference between this and [error].
  gone('gone');

  const DownloadState(this.wireName);

  final String wireName;

  /// A state this build does not know — a registry written by a newer one —
  /// reads back as [queued], which is what the Rust side's own deserializer
  /// does with it. Anything but a string is [queued] too.
  static DownloadState parse(Object? value) => values.firstWhere(
    (state) => state.wireName == value,
    orElse: () => queued,
  );
}

/// One row of the registry: a file of a torrent kept on the device.
final class DownloadView {
  const DownloadView(this.json);

  final Map<String, dynamic> json;

  /// The meta this belongs to (`tt0111161`).
  String get metaId => json['metaId'] as String? ?? '';

  /// The video inside it; the meta id itself for a movie, and
  /// `tt0903747:1:1` for an episode.
  String get videoId => json['videoId'] as String? ?? '';

  /// The registry key, `"{metaId}:{videoId}"` — what a removal names. A
  /// video id has colons of its own, so a key is built and compared, never
  /// split.
  String get key => keyFor(metaId, videoId);

  /// The key a meta/video pair would have.
  static String keyFor(String metaId, String videoId) => '$metaId:$videoId';

  /// stremio-core's meta type (`movie`, `series`, ...).
  String get type => json['type'] as String? ?? '';

  /// What a list row shows.
  String get name => json['name'] as String? ?? '';

  String? get poster => json['poster'] as String?;

  /// The addon's stream, verbatim: `Load Player` takes this back.
  StreamInfo get stream =>
      StreamInfo(json['stream'] as Map<String, dynamic>? ?? const {});

  String get infoHash => json['infoHash'] as String? ?? '';

  /// The file within the torrent. Always resolved: a stream that named none
  /// was pinned as the file it would have played.
  int get fileIdx => (json['fileIdx'] as num?)?.toInt() ?? 0;

  /// The stream's trackers, as the pin was taken with.
  List<String> get announce => [
    for (final tracker in (json['announce'] as List<dynamic>? ?? const []))
      if (tracker is String) tracker,
  ];

  /// Where the file is on disk, once the server knows.
  String? get path => json['path'] as String?;

  /// The file's full length in bytes; 0 until the metadata resolves.
  int get size => (json['size'] as num?)?.toInt() ?? 0;

  int get downloaded => (json['downloaded'] as num?)?.toInt() ?? 0;

  DownloadState get state => DownloadState.parse(json['state']);

  bool get isComplete => state == DownloadState.complete;

  /// Still on its way: not whole on the device, and not one of the two
  /// states nothing is working on. The same test `Entry::unfinished` in
  /// `rust/src/downloads.rs` makes, which is what decides whether the
  /// progress ticker keeps polling -- an errored entry counts, because a
  /// peer can still turn up, and a [DownloadState.gone] one does not,
  /// because nothing is fetching it and nothing will until it is asked
  /// for again.
  bool get isUnfinished =>
      state != DownloadState.complete &&
      state != DownloadState.paused &&
      state != DownloadState.gone;

  /// The server's reason this is not progressing, when it gave one. Never
  /// names a local path.
  String? get error => json['error'] as String?;

  DateTime? get createdAt => _date('createdAt');

  /// When the file first became whole; null while it is not.
  DateTime? get completedAt => _date('completedAt');

  DateTime? get lastPlayedAt => _date('lastPlayedAt');

  /// The `MetaItem` snapshot taken when the download was added, so Details
  /// renders with no network.
  Map<String, dynamic>? get meta => json['meta'] as Map<String, dynamic>?;

  /// The addon request the stream came from, for `Load Player`.
  Map<String, dynamic>? get streamRequest =>
      json['streamRequest'] as Map<String, dynamic>?;

  /// The addon request the meta came from, for `Load Player`.
  Map<String, dynamic>? get metaRequest =>
      json['metaRequest'] as Map<String, dynamic>?;

  /// `0..1` of the file, for a progress bar; null while there is nothing to
  /// be a fraction of (a magnet still resolving reports no size). A complete
  /// download is 1 whatever the counters say.
  double? get progress {
    if (isComplete) return 1;
    if (size <= 0) return null;
    return (downloaded / size).clamp(0, 1).toDouble();
  }

  /// `32.8 kB`, `1.4 GB`: the file's length for a row.
  String get sizeLabel => humanSize(size);

  /// The same for what is on disk of it.
  String get downloadedLabel => humanSize(downloaded);

  /// [bytes] in the decimal units storage is sold and shown in (the same
  /// ones the player's overlay counts MB/s in), one decimal below 100 of a
  /// unit and none above it.
  static String humanSize(int bytes) {
    if (bytes < 1000) return '$bytes B';
    const units = ['kB', 'MB', 'GB', 'TB', 'PB'];
    var value = bytes / 1000;
    var unit = 0;
    while (value >= 1000 && unit < units.length - 1) {
      value /= 1000;
      unit++;
    }
    // 999_999 B is 999.999 kB, which rounds to `1000 kB`: a unit that does
    // not exist. Promote it once more so it reads `1.0 MB`.
    if (value.round() >= 1000 && unit < units.length - 1) {
      value /= 1000;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }

  DateTime? _date(String key) {
    final value = json[key];
    return value is String ? DateTime.tryParse(value) : null;
  }

  @override
  String toString() => 'DownloadView($key, ${state.wireName})';
}

/// One row's progress, as the feed reports it: what moves while a download
/// runs, keyed by the entry it belongs to.
///
/// The whole entry is what a listing is for. A progress event carries these
/// six fields instead -- the `MetaItem` snapshot, the raw stream JSON and
/// the two addon requests would otherwise be decoded on the UI isolate once
/// a second per row, to say that a byte count moved.
final class DownloadProgress {
  const DownloadProgress(this.json);

  final Map<String, dynamic> json;

  /// The fields a row carries besides its [key], in the order the Rust side
  /// writes them.
  static const List<String> fields = [
    'downloaded',
    'size',
    'state',
    'path',
    'error',
    'completedAt',
  ];

  /// The entry this belongs to, `"{metaId}:{videoId}"`.
  String get key => json['key'] as String? ?? '';

  int get downloaded => (json['downloaded'] as num?)?.toInt() ?? 0;
  int get size => (json['size'] as num?)?.toInt() ?? 0;
  DownloadState get state => DownloadState.parse(json['state']);
  String? get path => json['path'] as String?;
  String? get error => json['error'] as String?;
  DateTime? get completedAt {
    final value = json['completedAt'];
    return value is String ? DateTime.tryParse(value) : null;
  }

  /// What to lay over the entry [key] names, verbatim: a field the event
  /// left out is not a field set to null.
  Map<String, dynamic> get changes => {
    for (final field in fields)
      if (json.containsKey(field)) field: json[field],
  };

  @override
  String toString() => 'DownloadProgress($key, $downloaded/$size)';
}

/// What the progress feed carries: the narrow rows the ticker pushes, or a
/// whole listing envelope. Either is folded into what a screen already has
/// with [applyTo].
sealed class DownloadsUpdate {
  const DownloadsUpdate();

  /// Reads whichever shape arrived. A `progress` array is the ticker's
  /// narrow event; a `removed` array names the entries that are gone (what
  /// the client pushes for its own removals, and the shape the Rust side
  /// would push if `remove` ever emitted); anything else is read as a
  /// listing, which is what every build before the narrow one pushed.
  factory DownloadsUpdate.fromJson(Map<String, dynamic> json) {
    final progress = json['progress'];
    if (progress is List) {
      return DownloadsProgressUpdate([
        for (final row in progress)
          if (row is Map<String, dynamic>) DownloadProgress(row),
      ]);
    }
    final removed = json['removed'];
    if (removed is List) {
      return DownloadsRemovalUpdate([
        for (final key in removed)
          if (key is String) key,
      ]);
    }
    return DownloadsListingUpdate(DownloadsRegistry.fromJson(json));
  }

  /// [registry] with this update laid over it.
  DownloadsRegistry applyTo(DownloadsRegistry registry);
}

/// The rows that moved.
final class DownloadsProgressUpdate extends DownloadsUpdate {
  const DownloadsProgressUpdate(this.rows);

  final List<DownloadProgress> rows;

  @override
  DownloadsRegistry applyTo(DownloadsRegistry registry) =>
      registry.withProgress(rows);

  @override
  String toString() => 'DownloadsProgressUpdate(${rows.length} rows)';
}

/// The entries that are gone. The other two shapes can only add or move a
/// row -- a listing envelope is merged, a progress row is laid over -- so
/// without this a removal reached nobody: the Rust side emits nothing for
/// one, and whoever held a registry kept the row until they listed again.
/// [DownloadsClient.remove] pushes one for the key it dropped.
final class DownloadsRemovalUpdate extends DownloadsUpdate {
  const DownloadsRemovalUpdate(this.keys);

  final List<String> keys;

  @override
  DownloadsRegistry applyTo(DownloadsRegistry registry) =>
      registry.without(keys);

  @override
  String toString() => 'DownloadsRemovalUpdate($keys)';
}

/// A whole registry envelope, every entry it names.
final class DownloadsListingUpdate extends DownloadsUpdate {
  const DownloadsListingUpdate(this.registry);

  final DownloadsRegistry registry;

  @override
  DownloadsRegistry applyTo(DownloadsRegistry registry) =>
      registry.merge(this.registry);

  @override
  String toString() => 'DownloadsListingUpdate($registry)';
}

/// `downloads.json` as a whole: what `downloads_list` answers and what a
/// progress event carries.
final class DownloadsRegistry {
  const DownloadsRegistry({this.version = 1, this.items = const {}});

  /// The file format's version, so a payload from a newer build is
  /// recognisable as one.
  final int version;

  /// Every download, by [DownloadView.key].
  final Map<String, DownloadView> items;

  /// Nothing downloaded, and what a failed read falls back to.
  static const DownloadsRegistry empty = DownloadsRegistry();

  factory DownloadsRegistry.fromJson(Map<String, dynamic> json) {
    final items = json['items'] as Map<String, dynamic>? ?? const {};
    return DownloadsRegistry(
      version: (json['version'] as num?)?.toInt() ?? 1,
      items: {
        for (final entry in items.entries)
          if (entry.value is Map<String, dynamic>)
            entry.key: DownloadView(entry.value as Map<String, dynamic>),
      },
    );
  }

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;
  int get length => items.length;

  DownloadView? operator [](String key) => items[key];

  /// The download of one video, if there is one.
  DownloadView? forVideo(String metaId, String videoId) =>
      items[DownloadView.keyFor(metaId, videoId)];

  /// Newest addition first, which is the order a downloads list shows; an
  /// entry with no `createdAt` sorts last, and ties go by key so the order
  /// never wobbles between rebuilds.
  List<DownloadView> get newestFirst {
    final sorted = items.values.toList();
    sorted.sort((a, b) {
      final left = a.createdAt;
      final right = b.createdAt;
      if (left == null || right == null) {
        if (left != right) return left == null ? 1 : -1;
      } else if (left != right) {
        return right.compareTo(left);
      }
      return a.key.compareTo(b.key);
    });
    return sorted;
  }

  /// This registry with [rows]' numbers laid over the entries they name.
  /// A row for an entry no listing has brought yet is dropped: there is
  /// nothing to lay it over, and the next listing carries the whole of it
  /// anyway.
  DownloadsRegistry withProgress(Iterable<DownloadProgress> rows) {
    final merged = {...items};
    for (final row in rows) {
      final entry = merged[row.key];
      if (entry == null) continue;
      merged[row.key] = DownloadView({...entry.json, ...row.changes});
    }
    return DownloadsRegistry(version: version, items: merged);
  }

  /// This registry without the entries [keys] name. A key nothing holds
  /// changes nothing.
  DownloadsRegistry without(Iterable<String> keys) {
    final kept = {...items};
    for (final key in keys) {
      kept.remove(key);
    }
    return DownloadsRegistry(version: version, items: kept);
  }

  /// This registry with [update]'s entries laid over it. A listing update
  /// carries only what it knows about, so folding one in is how a screen
  /// keeps the full picture; an entry that was *removed* is in no listing,
  /// and only a [DownloadsRemovalUpdate] or a fresh listing drops it.
  DownloadsRegistry merge(DownloadsRegistry update) => DownloadsRegistry(
    version: update.version,
    items: {...items, ...update.items},
  );

  @override
  String toString() => 'DownloadsRegistry(v$version, ${items.length} items)';
}
