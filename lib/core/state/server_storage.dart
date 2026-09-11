import 'download.dart';

/// One filesystem's room, as the server's own volume sees it.
class StorageVolume {
  const StorageVolume({required this.path, this.freeBytes, this.totalBytes});

  factory StorageVolume.fromJson(Map<String, dynamic> json) => StorageVolume(
    path: json['path'] as String? ?? '',
    freeBytes: (json['freeBytes'] as num?)?.toInt(),
    totalBytes: (json['totalBytes'] as num?)?.toInt(),
  );

  final String path;

  /// Free and total bytes, null when the volume could not be asked --
  /// which is "unknown", never "full": a volume nobody could measure is
  /// not an empty one.
  final int? freeBytes;
  final int? totalBytes;

  /// `3.4 GB free of 57.2 GB`, or what is known of it.
  String get label {
    final free = freeBytes;
    final total = totalBytes;
    if (free == null && total == null) return 'unknown';
    if (free == null) {
      return 'of ${DownloadView.humanSize(total!)}, free unknown';
    }
    if (total == null) return '${DownloadView.humanSize(free)} free';
    return '${DownloadView.humanSize(free)} free of '
        '${DownloadView.humanSize(total)}';
  }

  /// How full the volume is, `0..1`, or null with nothing to divide.
  double? get usedFraction {
    final free = freeBytes;
    final total = totalBytes;
    if (free == null || total == null || total <= 0) return null;
    return ((total - free) / total).clamp(0, 1).toDouble();
  }
}

/// What the embedded server's storage costs right now: the one root every
/// torrent byte on this device is under, what is in it against its limit,
/// and the room left on the volume it is on.
///
/// The first question about a playback that misbehaves is whether the
/// device is full -- bytes arriving with no verified progress is what
/// failing writes look like -- and the second is whether the cache is over
/// the limit the server sizes it against. Both are read over FFI
/// (`server_storage_report`); the app never asks the server over HTTP.
class ServerStorage {
  const ServerStorage({
    required this.cacheDir,
    required this.cacheUsedBytes,
    required this.cacheVolume,
    this.cacheLimitBytes,
  });

  factory ServerStorage.fromJson(Map<String, dynamic> json) => ServerStorage(
    cacheDir: json['cacheDir'] as String? ?? '',
    cacheUsedBytes: (json['cacheUsedBytes'] as num?)?.toInt() ?? 0,
    cacheLimitBytes: (json['cacheLimitBytes'] as num?)?.toInt(),
    cacheVolume: StorageVolume.fromJson(
      (json['cacheVolume'] as Map<String, dynamic>?) ?? const {},
    ),
  );

  /// The server's `cacheRoot`: the one root, where the piece store the
  /// streaming cache and the kept downloads share lives, along with the
  /// session's records and what the proxy cached.
  final String cacheDir;

  /// What the cache occupies: the server's own count of its piece store
  /// and its proxy cache, the same figure as [CacheUsage.totalBytes] and
  /// not a walk of the root. So it is a total and never a floor, and the
  /// storage screen's two figures cannot disagree by construction.
  final int cacheUsedBytes;

  /// The `cacheSize` setting, or null when nobody set one.
  ///
  /// The *setting*, not the limit in force: with no `cacheSize` the
  /// server still caps the cache at what the volume can give above its
  /// free-space floor, and [CacheUsage.limitBytes] is that number. So a
  /// null here means "unconfigured", never "unbounded", and the storage
  /// screen can rightly call a cache over its limit while this line says
  /// no size was chosen.
  final int? cacheLimitBytes;

  final StorageVolume cacheVolume;

  /// Whether the cache is bigger than the size that was configured for it.
  /// Says nothing about the device's own cap, which binds whether or not a
  /// `cacheSize` was ever set -- see [cacheLimitBytes].
  bool get overLimit {
    final limit = cacheLimitBytes;
    return limit != null && cacheUsedBytes > limit;
  }

  /// `17.0 GB of 10.0 GB limit`, or `17.0 GB, no cacheSize set`.
  ///
  /// Named after the setting rather than after "a limit", because there is
  /// always a limit: with no `cacheSize` the device's free space is what
  /// caps the cache, and a line reading `no limit set` beside a storage
  /// screen saying the cache is over its limit had the app contradicting
  /// itself. The volume's own line is directly under this one, which is
  /// where the room actually is.
  String get cacheLabel {
    final used = DownloadView.humanSize(cacheUsedBytes);
    final limit = cacheLimitBytes;
    return limit == null
        ? '$used, no cacheSize set'
        : '$used of ${DownloadView.humanSize(limit)} limit';
  }

  /// The lines the diagnostics header carries. Everything a person should
  /// look at first when playback misbehaves, in front of the log rather
  /// than buried in it.
  List<String> get reportLines => [
    'cache: $cacheLabel · $cacheDir',
    'disk: ${cacheVolume.label}',
  ];

  /// What those lines say when the report could not be read at all. The
  /// header keeps its shape either way: a missing line reads as a missing
  /// section, an `unknown` reads as an answer nobody could get.
  static const List<String> unknownReportLines = [
    'cache: unknown',
    'disk: unknown',
  ];
}

/// What the server's cache currently occupies against its `cacheSize`
/// limit, read without evicting anything
/// (`ServerHandle::cache_usage`/`GET /cache.json`).
///
/// [totalBytes] and [limitBytes] are occupancy, not apparent length -- the
/// server counts allocated blocks -- so this is the number to hold against
/// the limit, and the one a part-streamed film's apparent length would
/// badly overstate. [protectedBytes]/[protectedFiles] are what a pinned
/// download or the window of the title played last keeps right now, which
/// a clean can never take: when they account for all of [totalBytes] and
/// the cache is still over [limitBytes], cleaning cannot help until
/// something else is played or something is unpinned.
///
/// The server answers from what its piece store and proxy cache say they
/// hold, not from a walk, so a read is cheap; it is still a worker call,
/// and it belongs on screen-open, on an explicit refresh, and after a
/// clean -- never on a timer.
class CacheUsage {
  const CacheUsage({
    required this.totalBytes,
    this.limitBytes,
    required this.protectedBytes,
    required this.protectedFiles,
  });

  factory CacheUsage.fromJson(Map<String, dynamic> json) => CacheUsage(
    totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
    limitBytes: (json['limitBytes'] as num?)?.toInt(),
    protectedBytes: (json['protectedBytes'] as num?)?.toInt() ?? 0,
    protectedFiles: (json['protectedFiles'] as num?)?.toInt() ?? 0,
  );

  /// Occupancy of the cache right now.
  final int totalBytes;

  /// The limit in force, the one the server's owners size the cache
  /// against, in the same accounting: the smaller of the `cacheSize`
  /// setting and what the volume can give while keeping its free-space
  /// floor (`CACHE_FREE_SPACE_FLOOR`, 512 MiB) clear -- so on a device with
  /// no `cacheSize` set this is still a number, and the number is the
  /// device's.
  ///
  /// Null only when neither caps anything: `cacheSize` unset *and* the
  /// volume's free space unreadable. That makes it a different question
  /// from [ServerStorage.cacheLimitBytes], which is the setting itself and
  /// is null whenever nobody chose one -- the header line and this screen
  /// are answering "what is enforced" and "what was configured", and on a
  /// small device those disagree.
  ///
  /// It also moves on its own: it is derived from free space, so anything
  /// else writing to the volume changes it between two reads with nothing
  /// having happened to the cache.
  final int? limitBytes;

  /// How much of [totalBytes] a clean may never take: a pinned download
  /// keeps it, or it is the window of the title played last.
  final int protectedBytes;

  /// How many files that is.
  final int protectedFiles;

  /// Whether the cache is bigger than the limit in force -- which on a
  /// device with no `cacheSize` set is the device's own.
  bool get overLimit {
    final limit = limitBytes;
    return limit != null && totalBytes > limit;
  }

  /// Whether cleaning cannot help right now: everything over the limit is
  /// what a kept download or the title played last is holding.
  bool get nothingEvictable => overLimit && protectedBytes >= totalBytes;

  /// `17.0 GB of 10.0 GB limit`, or `17.0 GB, no limit set`.
  String get label {
    final used = DownloadView.humanSize(totalBytes);
    final limit = limitBytes;
    return limit == null
        ? '$used, no limit set'
        : '$used of ${DownloadView.humanSize(limit)} limit';
  }
}

/// What one on-demand clean found and did
/// (`ServerHandle::clean_cache_now`/`POST /cache/clean`): the server asked
/// its torrent engine and its proxy cache for their slack, the passes they
/// run on their own as they go, so a pin and the window of the title
/// played last are never touched. Occupancy throughout, like
/// [CacheUsage].
class EvictionReport {
  const EvictionReport({
    required this.total,
    required this.protected,
    required this.protectedFiles,
    required this.freed,
    required this.deleted,
    required this.limit,
  });

  factory EvictionReport.fromJson(Map<String, dynamic> json) => EvictionReport(
    total: (json['total'] as num?)?.toInt() ?? 0,
    protected: (json['protected'] as num?)?.toInt() ?? 0,
    protectedFiles: (json['protectedFiles'] as num?)?.toInt() ?? 0,
    freed: (json['freed'] as num?)?.toInt() ?? 0,
    deleted: (json['deleted'] as num?)?.toInt() ?? 0,
    limit: (json['limit'] as num?)?.toInt(),
  );

  /// Occupancy of the cache once this pass finished.
  final int total;

  /// How much of [total] this pass could never touch: a pin, or the
  /// window of the title played last.
  final int protected;

  /// How many files that is.
  final int protectedFiles;

  /// Occupancy this pass reclaimed.
  final int freed;

  /// How many files that took.
  final int deleted;

  /// The limit this run enforced, on the same terms as
  /// [CacheUsage.limitBytes]: null only when nothing capped the cache at
  /// all.
  ///
  /// It was an `int` with 0 for "no limit" while the only limit was the
  /// `cacheSize` setting, which nobody sets to nothing. The device-derived
  /// cap reaches 0 on its own -- any volume whose occupancy plus free space
  /// is under the server's floor gets exactly that -- and a cap of 0 is the
  /// tightest there is, so reading it as "unlimited" said the opposite of
  /// the truth on the device that most needed the answer.
  final int? limit;

  /// Whether the run ended still over the limit. Not a failure: what is
  /// left belongs to a kept download or the title played last, named by
  /// [protected]/[protectedFiles].
  bool get stillOverLimit {
    final limit = this.limit;
    return limit != null && total > limit;
  }
}
