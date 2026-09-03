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
  paused('paused');

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
  /// narrow event; anything else is read as a listing, which is what every
  /// build before the narrow one pushed.
  factory DownloadsUpdate.fromJson(Map<String, dynamic> json) {
    final progress = json['progress'];
    if (progress is List) {
      return DownloadsProgressUpdate([
        for (final row in progress)
          if (row is Map<String, dynamic>) DownloadProgress(row),
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

/// A whole registry envelope, entries and destination and all.
final class DownloadsListingUpdate extends DownloadsUpdate {
  const DownloadsListingUpdate(this.registry);

  final DownloadsRegistry registry;

  @override
  DownloadsRegistry applyTo(DownloadsRegistry registry) =>
      registry.merge(this.registry);

  @override
  String toString() => 'DownloadsListingUpdate($registry)';
}

/// Which answer the registry holds about where the downloads go.
enum DownloadDestinationKind {
  /// Nobody has been asked yet, so a start-up may apply the platform's own
  /// default.
  unset,

  /// The app applied that default because nothing had been chosen. Settled,
  /// but nobody's answer: another build's default may replace it, and no
  /// screen presents it as something the user picked.
  platformDefault,

  /// `Default (with the cache)`, chosen on purpose: a null `downloadsDir`,
  /// and not an open question.
  cache,

  /// A folder the user chose.
  explicit,
}

/// Where the downloads were last answered to go, and by whom: the
/// registry's `destinationSettled`/`destinationChoice` pair, read as the one
/// thing it describes.
///
/// It lives in the registry rather than in the server's settings because
/// `downloadsDir` cannot say any of this -- a null there is both "with the
/// torrent cache, on purpose" and "nobody has been asked" -- and because the
/// server clears a `downloadsDir` it cannot prepare at boot, which would
/// take the answer with it.
final class DownloadDestination {
  const DownloadDestination._(this.kind, this.path);

  /// Nobody has been asked.
  const DownloadDestination.unset()
    : this._(DownloadDestinationKind.unset, null);

  /// The platform default the app applied on its own, at [path].
  const DownloadDestination.platformDefault(String path)
    : this._(DownloadDestinationKind.platformDefault, path);

  /// The torrent cache, chosen on purpose.
  const DownloadDestination.cache()
    : this._(DownloadDestinationKind.cache, null);

  /// The folder the user chose, spelled the way the server stored it
  /// (the server resolves a path before it keeps it).
  const DownloadDestination.explicit(String path)
    : this._(DownloadDestinationKind.explicit, path);

  /// Reads the pair the registry carries, as forgivingly as the Rust side
  /// writes it: a bare string is a folder chosen (the shape every build so
  /// far has written), an object names its own kind, and a shape this build
  /// does not know falls back on the two things always readable -- whether
  /// the question was settled, and whether a path was named.
  factory DownloadDestination.fromJson(bool settled, Object? choice) {
    DownloadDestination named(String? path) => path != null
        ? DownloadDestination.explicit(path)
        : settled
        ? const DownloadDestination.cache()
        : const DownloadDestination.unset();
    if (choice is String) return named(choice);
    if (choice is Map<String, dynamic>) {
      final path = choice['path'] as String?;
      switch (choice['kind']) {
        case 'platformDefault':
          // A default that names no directory has applied nothing.
          return path == null
              ? const DownloadDestination.unset()
              : DownloadDestination.platformDefault(path);
        case 'cache':
          return const DownloadDestination.cache();
        case 'unset':
          return const DownloadDestination.unset();
        default:
          return named(path);
      }
    }
    return named(null);
  }

  final DownloadDestinationKind kind;

  /// The folder it names, where it names one.
  final String? path;

  /// Whether where the downloads go has been answered at all -- by the
  /// user, or by the platform default a first run applies.
  bool get isSettled => kind != DownloadDestinationKind.unset;

  /// Whether the answer is the user's own, which is what a default must
  /// never overwrite.
  bool get isChosen =>
      kind == DownloadDestinationKind.cache ||
      kind == DownloadDestinationKind.explicit;

  @override
  bool operator ==(Object other) =>
      other is DownloadDestination && other.kind == kind && other.path == path;

  @override
  int get hashCode => Object.hash(kind, path);

  @override
  String toString() =>
      'DownloadDestination(${kind.name}${path == null ? '' : ', $path'})';
}

/// `downloads.json` as a whole: what `downloads_list` answers and what a
/// progress event carries.
final class DownloadsRegistry {
  const DownloadsRegistry({
    this.version = 1,
    this.items = const {},
    this.destination = const DownloadDestination.unset(),
  });

  /// The file format's version, so a payload from a newer build is
  /// recognisable as one.
  final int version;

  /// Every download, by [DownloadView.key].
  final Map<String, DownloadView> items;

  /// Where the downloads were answered to go, and by whom.
  /// [DownloadsClient.setDirectory] records the user's own answer,
  /// [DownloadsClient.applyDefaultDirectory] the platform default the app
  /// stands in with. Kept so a start-up can compare it with the live
  /// `downloadsDir`: a folder recorded here that the settings no longer
  /// have is one the server cleared at boot because it could not prepare
  /// it, and one worth asking for again.
  final DownloadDestination destination;

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
      destination: DownloadDestination.fromJson(
        json['destinationSettled'] == true,
        json['destinationChoice'],
      ),
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
    return DownloadsRegistry(
      version: version,
      items: merged,
      destination: destination,
    );
  }

  /// This registry with [update]'s entries laid over it. A listing update
  /// carries only what it knows about, so folding one in is how a screen
  /// keeps the full picture; an entry that was *removed* is in no update,
  /// and only a fresh listing drops it.
  DownloadsRegistry merge(DownloadsRegistry update) => DownloadsRegistry(
    version: update.version,
    items: {...items, ...update.items},
    // An update that says nothing about the destination is not an update
    // that unsettles it: an unset destination in one means "not said", not
    // "nobody has answered after all".
    destination: update.destination.isSettled
        ? update.destination
        : destination,
  );

  @override
  String toString() => 'DownloadsRegistry(v$version, ${items.length} items)';
}
