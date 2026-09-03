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

/// What the embedded server's storage costs right now: the torrent cache
/// against its limit, and the room left on the volumes it writes to.
///
/// The first question about a playback that misbehaves is whether the
/// device is full -- bytes arriving with no verified progress is what
/// failing writes look like -- and the second is whether the cache is over
/// the limit its cleaner is supposed to hold it to. Both are read over FFI
/// (`server_storage_report`); the app never asks the server over HTTP.
class ServerStorage {
  const ServerStorage({
    required this.cacheDir,
    required this.cacheUsedBytes,
    required this.cacheVolume,
    this.cacheLimitBytes,
    this.cacheComplete = true,
    this.downloadsVolume,
  });

  factory ServerStorage.fromJson(Map<String, dynamic> json) => ServerStorage(
    cacheDir: json['cacheDir'] as String? ?? '',
    cacheUsedBytes: (json['cacheUsedBytes'] as num?)?.toInt() ?? 0,
    cacheLimitBytes: (json['cacheLimitBytes'] as num?)?.toInt(),
    cacheComplete: json['cacheComplete'] as bool? ?? true,
    cacheVolume: StorageVolume.fromJson(
      (json['cacheVolume'] as Map<String, dynamic>?) ?? const {},
    ),
    downloadsVolume: json['downloadsVolume'] == null
        ? null
        : StorageVolume.fromJson(
            json['downloadsVolume'] as Map<String, dynamic>,
          ),
  );

  /// The server's `cacheRoot`.
  final String cacheDir;

  /// What is under it, offline downloads excluded (they are not cache).
  final int cacheUsedBytes;

  /// The `cacheSize` setting, or null for no limit.
  final int? cacheLimitBytes;

  /// False when part of the tree could not be read, which makes
  /// [cacheUsedBytes] a floor rather than a total.
  final bool cacheComplete;

  final StorageVolume cacheVolume;

  /// The volume offline downloads go to, when the server has a
  /// `downloadsDir` on a different filesystem from the cache's. Null
  /// otherwise: a second identical line explains nothing.
  final StorageVolume? downloadsVolume;

  /// Whether the cache is bigger than the limit it is supposed to be held
  /// to -- a cleaner that is reclaiming nothing, which fills the device.
  bool get overLimit {
    final limit = cacheLimitBytes;
    return limit != null && cacheUsedBytes > limit;
  }

  /// `17.0 GB of 10.0 GB limit`, or `17.0 GB, no limit set`.
  String get cacheLabel {
    final used = DownloadView.humanSize(cacheUsedBytes);
    final limit = cacheLimitBytes;
    final prefix = cacheComplete ? used : 'at least $used';
    return limit == null
        ? '$prefix, no limit set'
        : '$prefix of ${DownloadView.humanSize(limit)} limit';
  }

  /// The lines the diagnostics header carries. Everything a person should
  /// look at first when playback misbehaves, in front of the log rather
  /// than buried in it.
  List<String> get reportLines => [
    'cache: $cacheLabel · $cacheDir',
    'disk: ${cacheVolume.label}',
    if (downloadsVolume case final downloads?)
      'downloads: ${downloads.label} · ${downloads.path}',
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
/// server counts allocated blocks, the same accounting its cleaner uses --
/// so this is the number to hold against the limit, and the one a
/// part-streamed film's apparent length would badly overstate.
/// [protectedBytes]/[protectedFiles] are what a live engine is writing or a
/// pinned download keeps right now, which a clean pass can never touch:
/// when they account for all of [totalBytes] and the cache is still over
/// [limitBytes], cleaning cannot help until playback stops or something is
/// unpinned.
///
/// The walk behind this call costs one `stat` per file currently in the
/// cache and is not bounded server-side, so it belongs on screen-open, on
/// an explicit refresh, and after a clean -- never on a timer.
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

  /// The `cacheSize` setting in the same accounting. Null only when the
  /// cache is truly unlimited, matching the setting's own null.
  final int? limitBytes;

  /// How much of [totalBytes] a clean pass may never touch: a live engine
  /// is writing it, or a pinned download keeps it.
  final int protectedBytes;

  /// How many files that is.
  final int protectedFiles;

  /// Whether the cache is bigger than its configured limit.
  bool get overLimit {
    final limit = limitBytes;
    return limit != null && totalBytes > limit;
  }

  /// Whether cleaning cannot help right now: everything over the limit is
  /// what a live stream or a kept download is holding.
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

/// What one on-demand clean pass found and did
/// (`ServerHandle::clean_cache_now`/`POST /cache/clean`) -- the exact
/// function the server's own scheduled sweep runs, so it respects exactly
/// the same protections. Occupancy throughout, like [CacheUsage].
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
    limit: (json['limit'] as num?)?.toInt() ?? 0,
  );

  /// Occupancy of the cache once this pass finished.
  final int total;

  /// How much of [total] this pass could never touch: a live engine or a
  /// pin.
  final int protected;

  /// How many files that is.
  final int protectedFiles;

  /// Occupancy this pass reclaimed.
  final int freed;

  /// How many files that took.
  final int deleted;

  /// The limit this run was given; `0` means "no limit" -- unlike
  /// [CacheUsage.limitBytes] this is never null, matching the server's own
  /// `EvictionReport::shortfall_message`.
  final int limit;

  /// Whether the run ended still over the limit. Not a failure: what is
  /// left belongs to a live stream or a kept download, named by
  /// [protected]/[protectedFiles].
  bool get stillOverLimit => limit != 0 && total > limit;
}
