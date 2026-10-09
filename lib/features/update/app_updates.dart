import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/diagnostics_log.dart';
import '../../core/prefs_client.dart';
import '../../core/server_client.dart';
import 'apk_download.dart';
import 'apk_installer.dart';
import 'install_room.dart';
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

/// What [AppUpdates.makeRoom] is doing, for the line the dialog shows.
enum RoomStep {
  /// Reading the room on the data volume.
  measuring,

  /// The gentle clean: what nobody plays and nobody kept.
  cleaning,

  /// The full clear: streams stopped, everything no download keeps
  /// deleted.
  clearing,
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
///
/// **Room before an install.** An Update press measures the data volume
/// before the download and again before the install, and makes room in
/// three steps when it is short ([makeRoom]): the gentle clean, then the
/// full clear, then the "Not enough space" dialog. A television whose
/// cache has filled its disk would otherwise download the APK and have
/// Android refuse it. Nothing else here reclaims anything -- the daily
/// look and the offer never touch the cache.
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
    this.cache = const ServerClient(),
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

  /// The embedded server's cache, which [makeRoom] asks for what it can
  /// give back.
  final ServerCacheControl cache;

  /// How long [makeRoom] waits for the server's clean, and then for its
  /// clear, before it measures anyway.
  ///
  /// A clean is the server's owners unlinking what nobody is playing and
  /// nobody kept, on this device's own flash: well under a second as a
  /// rule, and a few on a television's eMMC with thousands of piece files
  /// to go. Thirty seconds lets a clean that is working finish, and keeps
  /// a server that does not answer from holding an update the viewer is
  /// watching a dialog for. What it freed by then is in the measurement
  /// either way: the clean is not cancelled, only no longer waited for.
  /// The clear deletes more and is waited for as long, for the same
  /// reasons.
  static const Duration cleanBound = Duration(seconds: 30);

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

  /// **Makes room for an APK of [apkBytes] and says whether it fits**:
  /// before the download when [downloaded] is false, before the install
  /// when it is true ([UpdateRoom.forApk]). Called only from an Update or
  /// Install press -- the user asked for the update, so no step here asks
  /// again -- never from the daily look.
  ///
  /// In steps, each taken only while the APK still does not fit, and each
  /// measured after:
  ///
  /// 1. **Measure.** A device with room is left alone.
  /// 2. **The gentle clean** -- Server storage's "Clean cache now": what
  ///    nobody is playing and nobody kept, never a kept download or the
  ///    part of the title played last around where it was left.
  /// 3. **The full clear** -- "Clear the cache": every stream stopped and
  ///    everything no download keeps deleted, the title played last
  ///    included. What is left after it is short is the dialog's, which
  ///    says what was cleared ([UpdateRoom.afterClearing]).
  ///
  /// Each server call is waited for at most [cleanBound]; what it freed by
  /// then is in the next measurement either way. [onStep] hears each step
  /// as it starts, for the dialog's line. Every step is logged with the
  /// free bytes before and after it.
  ///
  /// Null when the volume could not be measured: then nothing is refused
  /// here and Android decides, as it always did.
  Future<UpdateRoom?> makeRoom({
    required int apkBytes,
    required bool downloaded,
    void Function(RoomStep step)? onStep,
  }) async {
    final when = downloaded ? 'install' : 'download';
    onStep?.call(RoomStep.measuring);
    var room = await _measure(apkBytes: apkBytes, downloaded: downloaded);
    if (room == null) {
      DiagnosticsLog.info('update', 'room before the $when: not measurable');
      return null;
    }
    DiagnosticsLog.info(
      'update',
      'room before the $when: ${room.freeBytes} bytes free, '
          '${room.neededBytes} needed',
    );
    if (room.fits) return room;

    onStep?.call(RoomStep.cleaning);
    int? freed;
    try {
      freed = (await cache.cleanCacheNow().timeout(cleanBound)).freed;
    } catch (error) {
      // No server, or still cleaning at the bound: the measurement below
      // is the answer either way.
      DiagnosticsLog.warn(
        'update',
        'the cache clean did not answer (${error.runtimeType})',
      );
    }
    final beforeClean = room.freeBytes;
    room = await _measure(apkBytes: apkBytes, downloaded: downloaded);
    _logStep('the cache clean', beforeClean, room);
    if (room == null || room.fits) return room;

    onStep?.call(RoomStep.clearing);
    int? cleared;
    try {
      cleared = (await cache.clearCache().timeout(cleanBound)).freed;
    } catch (error) {
      DiagnosticsLog.warn(
        'update',
        'the cache clear did not answer (${error.runtimeType})',
      );
    }
    final beforeClear = room.freeBytes;
    room = await _measure(apkBytes: apkBytes, downloaded: downloaded);
    _logStep('the cache clear', beforeClear, room);
    if (room == null || room.fits) return room;
    return room.afterClearing(
      freedBytes: cleared == null ? null : cleared + (freed ?? 0),
    );
  }

  /// The room on the data volume for an APK of [apkBytes], or null when
  /// it could not be read.
  Future<UpdateRoom?> _measure({
    required int apkBytes,
    required bool downloaded,
  }) async {
    DataVolumeRoom? volume;
    try {
      volume = await installer.room();
    } catch (_) {
      volume = null;
    }
    if (volume == null) return null;
    return UpdateRoom.forApk(
      apkBytes: apkBytes,
      volume: volume,
      downloaded: downloaded,
    );
  }

  /// One step of [makeRoom], in the log: the free bytes before and after.
  static void _logStep(String step, int before, UpdateRoom? after) =>
      DiagnosticsLog.info(
        'update',
        after == null
            ? 'after $step: $before bytes free before, not measurable after'
            : 'after $step: $before bytes free before, ${after.freeBytes} '
                  'after, ${after.neededBytes} needed',
      );

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
