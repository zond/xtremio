import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/prefs_client.dart';
import 'apk_download.dart';
import 'apk_installer.dart';
import 'release_version.dart';
import 'releases.dart';

/// What one look at the latest release found.
sealed class UpdateCheck {
  const UpdateCheck();
}

/// No look was taken: the build does not check by itself, or it already
/// did today.
class UpdateNotChecked extends UpdateCheck {
  const UpdateNotChecked();
}

/// [release] is newer than this build.
class UpdateAvailable extends UpdateCheck {
  const UpdateAvailable(this.release);
  final ReleaseInfo release;
}

/// This build is [release] or newer.
class UpdateUpToDate extends UpdateCheck {
  const UpdateUpToDate(this.release);
  final ReleaseInfo release;
}

/// This build carries no version to compare [release] with.
class UpdateUnversioned extends UpdateCheck {
  const UpdateUnversioned(this.release);
  final ReleaseInfo release;
}

/// GitHub could not be asked, or did not answer with a release.
class UpdateCheckFailed extends UpdateCheck {
  const UpdateCheckFailed(this.message);
  final String message;
}

/// The app's updates: whether a newer release is out, and what to do with
/// one -- install it over this app (an Android release build) or point at
/// its page (everything else).
///
/// **At most once a day by itself.** [checkIfDue] asks only when the last
/// look was [interval] ago or longer, and the look is written down
/// (`AppPrefs.updateCheckedAt`) *before* GitHub is asked: the unauthenticated
/// API allows 60 requests an hour per IP, shared with everything else on
/// the network, so a look that failed counts as one too. A clock that went
/// backwards makes the look due rather than leaving it stuck in a future.
/// "Check for updates" in Settings ([check] with `manual`) asks whenever it
/// is pressed and says "up to date" too.
///
/// **What is offered.** A release newer than this build, unless it is the
/// one "Skip this version" named (`AppPrefs.updateSkippedTag`) -- a newer
/// one than that is offered again. "Later" puts the offer away for this
/// run. A manual check offers the skipped release as well: it was asked
/// for.
class AppUpdates {
  AppUpdates({
    required this.prefs,
    this.identity = BuildIdentity.current,
    ReleaseSource? source,
    this.installer = const PlatformApkInstaller(),
    ApkDownloader Function()? downloader,
    Future<Directory> Function()? downloadsDirectory,
    DateTime Function()? clock,
    bool? installsHere,
  }) : source = source ?? GitHubReleaseSource(),
       newDownloader = downloader ?? ApkDownloader.new,
       downloadsDirectory = downloadsDirectory ?? _defaultDirectory,
       clock = clock ?? DateTime.now,
       installsHere =
           installsHere ?? defaultTargetPlatform == TargetPlatform.android;

  /// How long a look counts for.
  static const Duration interval = Duration(days: 1);

  final AppPrefs prefs;
  final BuildIdentity identity;
  final ReleaseSource source;
  final ApkInstaller installer;
  final ApkDownloader Function() newDownloader;

  /// Where an update's APK is downloaded to: app-specific storage, which
  /// nothing else on the device reads and the app's uninstall removes.
  final Future<Directory> Function() downloadsDirectory;
  final DateTime Function() clock;

  /// The platform installs APKs (Android). Everywhere else an update is a
  /// page to open.
  final bool installsHere;

  /// Whether an update can be installed from inside the app rather than
  /// only pointed at. See [BuildIdentity.canInstall] for why a debug build
  /// cannot.
  bool get canInstall => installsHere && identity.canInstall;

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/updates');

  /// Whether the daily look is due at [now].
  static bool isDue(DateTime? last, DateTime now) =>
      last == null || now.isBefore(last) || !now.isBefore(last.add(interval));

  /// The look the app takes by itself at start-up. See the class.
  Future<UpdateCheck> checkIfDue() async {
    if (!identity.checksByItself) return const UpdateNotChecked();
    if (!isDue(prefs.updateCheckedAt, clock())) return const UpdateNotChecked();
    final result = await check();
    if (result is UpdateAvailable &&
        result.release.tag == prefs.updateSkippedTag) {
      return UpdateUpToDate(result.release);
    }
    return result;
  }

  /// Asks for the latest release now, whatever the day's look said.
  Future<UpdateCheck> check() async {
    await prefs.setUpdateCheckedAt(clock());
    final ReleaseInfo release;
    try {
      release = await source.latest();
    } on HttpException catch (error) {
      return UpdateCheckFailed(error.message);
    } on FormatException catch (error) {
      return UpdateCheckFailed(error.message);
    } catch (error) {
      return UpdateCheckFailed(
        'GitHub could not be reached (${error.runtimeType})',
      );
    }
    unawaited(_sweep(keep: release));
    if (identity.parsed == null) return UpdateUnversioned(release);
    return identity.isOlderThan(release.version)
        ? UpdateAvailable(release)
        : UpdateUpToDate(release);
  }

  /// "Skip this version": [release] is not offered by the daily look again.
  Future<void> skip(ReleaseInfo release) =>
      prefs.setUpdateSkippedTag(release.tag);

  /// The file [release]'s APK for [abi] is downloaded to.
  Future<File> apkFile(ReleaseInfo release, String abi) async => File(
    '${(await downloadsDirectory()).path}/xtremio-${release.tag}-$abi.apk',
  );

  /// Deletes every downloaded update but [keep]'s: one that was installed,
  /// or one a newer release has replaced. A part of [keep]'s stays, so a
  /// download that stopped is picked up where it left off.
  Future<void> _sweep({required ReleaseInfo keep}) async {
    if (!canInstall) return;
    try {
      final dir = await downloadsDirectory();
      if (!await dir.exists()) return;
      final ours = identity.isOlderThan(keep.version)
          ? 'xtremio-${keep.tag}-'
          : null;
      await for (final entry in dir.list()) {
        final name = entry.uri.pathSegments.last;
        if (ours != null && name.startsWith(ours)) continue;
        await entry.delete(recursive: true);
      }
    } catch (error) {
      if (kDebugMode) debugPrint('update sweep failed: ${error.runtimeType}');
    }
  }
}

/// Hands [AppUpdates] down the tree, for Settings' "Check for updates".
class AppUpdatesScope extends InheritedWidget {
  const AppUpdatesScope({
    super.key,
    required this.updates,
    required super.child,
  });

  final AppUpdates updates;

  static AppUpdates? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppUpdatesScope>()?.updates;

  @override
  bool updateShouldNotify(AppUpdatesScope oldWidget) =>
      updates != oldWidget.updates;
}
