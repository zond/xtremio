import 'dart:async';
import 'dart:io';

import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/update/apk_download.dart';
import 'package:xtremio/features/update/apk_installer.dart';
import 'package:xtremio/features/update/app_updates.dart';
import 'package:xtremio/features/update/install_room.dart';
import 'package:xtremio/features/update/release_version.dart';
import 'package:xtremio/features/update/releases.dart';

import 'fake_server_cache.dart';

/// A stamped, clean release build of 0.1.13: one that checks by itself.
const BuildIdentity releaseBuild = BuildIdentity(
  version: '0.1.13+1',
  commit: 'cda9225',
  isReleaseBuild: true,
);

/// The same version from a debug build: `com.zond.xtremio.debug`.
const BuildIdentity debugBuild = BuildIdentity(
  version: '0.1.13+1',
  commit: 'cda9225',
  isReleaseBuild: false,
);

const String sampleDigest =
    'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// A release as `ReleaseInfo.fromGitHub` would read it, with both APKs.
ReleaseInfo sampleRelease({
  String tag = 'v0.1.14',
  String notes = '## What changed\n\n- **Faster** start\n- Fewer stalls',
}) => ReleaseInfo(
  tag: tag,
  version: ReleaseVersion.parse(tag)!,
  notes: notes,
  page: Uri.parse('https://github.com/zond/xtremio/releases/tag/$tag'),
  assets: [
    for (final abi in ['arm64-v8a', 'armeabi-v7a'])
      ReleaseAsset(
        name: 'xtremio-$abi.apk',
        url: Uri.parse(
          'https://github.com/zond/xtremio/releases/download/$tag/'
          'xtremio-$abi.apk',
        ),
        size: 1000,
        digest: sampleDigest,
      ),
  ],
);

/// Answers [release], or throws [error]; counts the questions.
class FakeReleaseSource implements ReleaseSource {
  FakeReleaseSource({this.release, this.error, this.gate});

  ReleaseInfo? release;
  Object? error;
  int asked = 0;

  /// Held until the test completes it, when there is one: GitHub taking
  /// its time.
  Completer<void>? gate;

  @override
  Future<ReleaseInfo> latest() async {
    asked++;
    await gate?.future;
    if (error case final error?) throw error;
    return release!;
  }
}

/// Records what the dialog asks of Android, and answers what the test says.
class FakeApkInstaller implements ApkInstaller {
  FakeApkInstaller({
    this.abi = 'arm64-v8a',
    this.allowed = true,
    this.settingsOpen = true,
    this.outcome = const InstallOutcome(InstallResult.success),
    this.volume = roomy,
    this.onInstall,
  });

  String? abi;
  bool allowed;
  bool settingsOpen;
  InstallOutcome outcome;

  /// What [room] answers; null is a volume nobody could measure.
  DataVolumeRoom? volume;

  /// Called as [install] is, for a test that wants to know what had
  /// happened by then.
  void Function()? onInstall;

  /// A 32 GB volume with 10 GB free: any update fits.
  static const DataVolumeRoom roomy = DataVolumeRoom(
    freeBytes: 10000000000,
    totalBytes: 32000000000,
  );

  /// Every path [install] was handed.
  final List<String> installed = [];
  int settingsOpened = 0;

  @override
  Future<String?> primaryAbi() async => abi;

  @override
  Future<bool> canRequestInstalls() async => allowed;

  @override
  Future<bool> openInstallPermission() async {
    settingsOpened++;
    return settingsOpen;
  }

  @override
  Future<DataVolumeRoom?> room() async => volume;

  @override
  Future<InstallOutcome> install(String path) async {
    onInstall?.call();
    installed.add(path);
    return outcome;
  }
}

/// A downloader that touches no network: it reports progress, then finishes
/// or throws [failure], each when the test completes [gate] (at once
/// without one).
class FakeApkDownloader extends ApkDownloader {
  FakeApkDownloader({this.failure, this.gate});

  final String? failure;
  final Completer<void>? gate;
  final List<Uri> asked = [];
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  Future<File> download({
    required Uri url,
    required File target,
    required String? digest,
    int expectedSize = 0,
    UpdateDownloadProgress? onProgress,
  }) async {
    asked.add(url);
    onProgress?.call(400, 1000);
    await gate?.future;
    if (failure case final failure?) throw UpdateDownloadException(failure);
    onProgress?.call(1000, 1000);
    return target;
  }
}

/// [AppUpdates] over fakes, at a fixed [now].
AppUpdates fakeUpdates({
  AppPrefs? prefs,
  BuildIdentity identity = releaseBuild,
  ReleaseSource? source,
  ApkInstaller? installer,
  ApkDownloader Function()? downloader,
  DateTime Function()? clock,
  bool installsHere = true,
  ServerCacheControl? cache,
}) => AppUpdates(
  prefs: prefs ?? AppPrefs.inMemory(),
  identity: identity,
  source: source ?? FakeReleaseSource(release: sampleRelease()),
  installer: installer ?? FakeApkInstaller(),
  downloader: downloader ?? FakeApkDownloader.new,
  downloadsDirectory: () async => Directory('/nonexistent/updates'),
  clock: clock ?? () => DateTime.utc(2026, 10, 3, 12),
  installsHere: installsHere,
  cache: cache ?? FakeServerCache(cleanResult: cleanedNothing),
);

/// A clean that found nothing to give back.
const EvictionReport cleanedNothing = EvictionReport(
  total: 0,
  protected: 0,
  protectedFiles: 0,
  freed: 0,
  deleted: 0,
  limit: null,
);
