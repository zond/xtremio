import 'package:flutter/foundation.dart';

import '../../core/units.dart';

/// The room on Android's data volume, the one an update is downloaded to
/// and installed on, as `AppUpdateChannel.kt` (`room`) reads it.
@immutable
class DataVolumeRoom {
  const DataVolumeRoom({
    required this.freeBytes,
    required this.totalBytes,
    this.thresholdPercent,
    this.thresholdMaxBytes,
  });

  /// From the channel's map; null for an answer that names no free space,
  /// which is "unknown" and never "full".
  static DataVolumeRoom? fromMap(Map<Object?, Object?>? map) {
    final free = (map?['freeBytes'] as num?)?.toInt();
    if (map == null || free == null) return null;
    return DataVolumeRoom(
      freeBytes: free,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      thresholdPercent: (map['thresholdPercent'] as num?)?.toInt(),
      thresholdMaxBytes: (map['thresholdMaxBytes'] as num?)?.toInt(),
    );
  }

  /// `Environment.getDataDirectory().usableSpace`.
  final int freeBytes;

  /// `Environment.getDataDirectory().totalSpace`; 0 when unreadable.
  final int totalBytes;

  /// The device's `sys_storage_threshold_percentage` and
  /// `sys_storage_threshold_max_bytes` (`Settings.Global`), null where the
  /// setting is unset or this app may not read it -- which is nearly
  /// everywhere, and means Android's defaults.
  final int? thresholdPercent;
  final int? thresholdMaxBytes;
}

/// Whether an update fits, and the arithmetic that says so.
///
/// **Android's rule.** The installer refuses a session whose size is more
/// than the data volume can allocate (`InstallLocationUtils.fitsOnInternal`,
/// "Requested internal only, but not enough space"), and what it can
/// allocate is the free space less the low-storage reserve
/// (`StorageManager.getAllocatableBytes`). The reserve is
/// `StorageManager.getStorageLowBytes`: the smaller of
/// `sys_storage_threshold_percentage` of the volume (default 5) and
/// `sys_storage_threshold_max_bytes` (default 500 MiB).
///
/// **What an update takes.** The session's size is the APK and the native
/// code Android unpacks from it (`calculateInstalledSize`), and the session
/// writes its own copy of the APK while the downloaded one is still on
/// disk: two APKs' worth on top of the reserve once it is downloaded
/// ([installFactor]), and the download's own copy before that. The native
/// code is less than the APK it is in, so two is an upper bound, and the
/// default reserve is used whenever the device's own settings cannot be
/// read.
///
/// Held against what was measured: a Chromecast with Google TV refused a
/// 50 MB update with 130-330 MB free and took it with about 500 MB. On its
/// few-GB volume the reserve is 200-300 MB, so this asks 350-450 MB before
/// the download and 300-400 MB before the install.
///
/// Free space is the volume's usable space, without the other apps'
/// caches Android could clear for an install: never more than Android
/// would find, so a "does not fit" here may be one Android would have
/// managed, and a "fits" is one it will.
@immutable
class UpdateRoom {
  const UpdateRoom({required this.freeBytes, required this.neededBytes});

  /// What the room on [volume] says about an APK of [apkBytes]: before the
  /// download when [downloaded] is false, before the install when true.
  factory UpdateRoom.forApk({
    required int apkBytes,
    required DataVolumeRoom volume,
    required bool downloaded,
  }) => UpdateRoom(
    freeBytes: volume.freeBytes,
    neededBytes:
        apkBytes * (downloaded ? installFactor : installFactor + 1) +
        lowStorageReserve(volume),
  );

  /// APKs' worth an install writes beside the downloaded one: the
  /// session's copy and, at most, the native code unpacked from it.
  static const int installFactor = 2;

  /// Android's defaults (`StorageManager`).
  static const int defaultThresholdPercent = 5;
  static const int defaultThresholdMaxBytes = 500 * 1024 * 1024;

  /// `StorageManager.getStorageLowBytes` on [volume]: what Android keeps
  /// free on it whatever an install wants. A volume whose size could not be
  /// read gets the cap.
  static int lowStorageReserve(DataVolumeRoom volume) {
    final percent = volume.thresholdPercent ?? defaultThresholdPercent;
    final cap = volume.thresholdMaxBytes ?? defaultThresholdMaxBytes;
    if (volume.totalBytes <= 0) return cap;
    final share = volume.totalBytes * percent ~/ 100;
    return share < cap ? share : cap;
  }

  final int freeBytes;
  final int neededBytes;

  bool get fits => freeBytes >= neededBytes;

  /// What the dialog says when it does not.
  String get shortText =>
      'The update needs ${formatBytes(neededBytes)} free on this device and '
      'there is ${formatBytes(freeBytes)}, after emptying the torrent cache '
      'of everything it could give back. What is left there is a download '
      'you kept or the title you played last; Server storage shows it.';
}
