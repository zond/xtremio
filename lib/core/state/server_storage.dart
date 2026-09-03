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
