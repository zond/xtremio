import 'package:xtremio/core/core.dart';

/// [ServerCacheControl] for widget tests: answers with what the test put in
/// it and counts what it was asked; cleaning takes no restart call to
/// record.
class FakeServerCache implements ServerCacheControl {
  FakeServerCache({
    this.usage,
    this.usageError,
    this.cleanResult,
    this.cleanError,
    this.clearResult = clearedNothing,
    this.clearError,
    this.onClean,
    this.onClear,
    ServerStorage? report,
  }) : report = report ?? defaultReport;

  CacheUsage? usage;
  Object? usageError;
  EvictionReport? cleanResult;
  Object? cleanError;
  CacheClearReport clearResult;
  Object? clearError;

  /// Called as [cleanCacheNow] and [clearCache] are, before they answer:
  /// what a test makes the clean or the clear free on the volume it
  /// measures.
  void Function()? onClean;
  void Function()? onClear;

  /// What [storage] answers: the root and the volume it is on.
  ServerStorage report;

  /// Thrown by [updateSettings], as the server refuses a root it cannot
  /// prepare.
  Object? settingsError;

  /// Every patch written, in order.
  final List<Map<String, dynamic>> patches = [];
  int reads = 0;
  int cleans = 0;
  int clears = 0;

  static const ServerStorage defaultReport = ServerStorage(
    cacheDir: '/data/cache/server',
    cacheUsedBytes: 17000000000,
    cacheLimitBytes: 10000000000,
    cacheVolume: StorageVolume(
      path: '/data/cache/server',
      freeBytes: 402653184,
      totalBytes: 57000000000,
    ),
  );

  @override
  Future<ServerStorage> storage() async {
    final error = usageError;
    if (error != null) throw error;
    return report;
  }

  @override
  Future<Map<String, dynamic>> updateSettings(
    Map<String, dynamic> patch,
  ) async {
    patches.add(patch);
    final error = settingsError;
    if (error != null) throw error;
    report = ServerStorage(
      cacheDir: patch['cacheRoot'] as String? ?? report.cacheDir,
      cacheUsedBytes: report.cacheUsedBytes,
      cacheLimitBytes: report.cacheLimitBytes,
      cacheVolume: report.cacheVolume,
    );
    return {'cacheRoot': report.cacheDir};
  }

  @override
  Future<CacheUsage> cacheUsage() async {
    reads++;
    final error = usageError;
    if (error != null) throw error;
    return usage!;
  }

  @override
  Future<EvictionReport> cleanCacheNow() async {
    cleans++;
    onClean?.call();
    final error = cleanError;
    if (error != null) throw error;
    return cleanResult!;
  }

  @override
  Future<CacheClearReport> clearCache() async {
    clears++;
    onClear?.call();
    final error = clearError;
    if (error != null) throw error;
    return clearResult;
  }
}

/// A clear on a server with nothing cached and nothing streaming.
const CacheClearReport clearedNothing = CacheClearReport(
  freed: 0,
  stopped: 0,
  deleted: 0,
  total: 0,
);

/// A cache well past its limit, with nothing protected -- a clean would
/// reclaim all of it.
const CacheUsage overLimitEvictable = CacheUsage(
  totalBytes: 17000000000,
  limitBytes: 10000000000,
  protectedBytes: 0,
  protectedFiles: 0,
);

/// A cache over its limit where everything left is a kept download or the
/// title played last: cleaning cannot help.
const CacheUsage overLimitNothingEvictable = CacheUsage(
  totalBytes: 12000000000,
  limitBytes: 10000000000,
  protectedBytes: 12000000000,
  protectedFiles: 3,
);
