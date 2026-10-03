import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How an install ended, as Android's `PackageInstaller` reported it
/// (`AppUpdateChannel.kt`, `InstallOutcome`).
enum InstallResult {
  /// Installed. On a self-update Android usually ends this process before
  /// anybody hears it.
  success,

  /// The viewer said no on Android's confirmation, or backed out of it.
  aborted,

  /// The new APK is signed with another key than the installed app: an
  /// install from before v0.1.8. Only uninstalling first gets past it.
  conflict,

  /// Android will not install it here: the wrong ABI, a version it calls a
  /// downgrade, an SDK it does not have.
  incompatible,

  /// The file is not a valid APK.
  invalid,

  /// Not enough space.
  storage,

  /// A policy or another app stopped it (Play Protect, a device admin).
  blocked,

  /// Anything else.
  failure;

  static InstallResult parse(Object? name) => InstallResult.values.firstWhere(
    (value) => value.name == name,
    orElse: () => InstallResult.failure,
  );
}

/// What an install attempt said: the outcome and Android's own words.
@immutable
class InstallOutcome {
  const InstallOutcome(this.result, [this.message]);

  final InstallResult result;

  /// `EXTRA_STATUS_MESSAGE`, which is Android's and in English.
  final String? message;
}

/// Hands a verified APK to Android. An interface so widget tests drive the
/// dialog through every outcome without a device.
abstract interface class ApkInstaller {
  /// `Build.SUPPORTED_ABIS[0]`, null where there is no Android to ask.
  Future<String?> primaryAbi();

  /// Whether this app may ask Android to install packages
  /// (`canRequestPackageInstalls`, the per-app "Install unknown apps"
  /// switch). False is not final: the install itself makes Android ask.
  Future<bool> canRequestInstalls();

  /// Opens this app's "Install unknown apps" switch in Android's settings;
  /// false when nothing on this device answers that screen.
  Future<bool> openInstallPermission();

  /// Installs the APK at [path] through a `PackageInstaller` session.
  /// Android always puts its own confirmation up first; this completes
  /// when the session ends (and not at all when the update replaces this
  /// process).
  Future<InstallOutcome> install(String path);
}

/// [ApkInstaller] over the `xtremio/update` channel (`AppUpdateChannel.kt`).
class PlatformApkInstaller implements ApkInstaller {
  const PlatformApkInstaller();

  static const MethodChannel channel = MethodChannel('xtremio/update');

  @override
  Future<String?> primaryAbi() async {
    try {
      return await channel.invokeMethod<String>('abi');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> canRequestInstalls() async =>
      await channel.invokeMethod<bool>('canRequestInstalls') ?? false;

  @override
  Future<bool> openInstallPermission() async =>
      await channel.invokeMethod<bool>('openInstallPermission') ?? false;

  @override
  Future<InstallOutcome> install(String path) async {
    try {
      final reply = await channel.invokeMapMethod<String, Object?>('install', {
        'path': path,
      });
      return InstallOutcome(
        InstallResult.parse(reply?['outcome']),
        reply?['message'] as String?,
      );
    } on PlatformException catch (error) {
      return InstallOutcome(InstallResult.failure, error.message ?? error.code);
    }
  }
}

/// What the dialog says about [outcome], for every outcome but success.
String installFailureText(InstallOutcome outcome) {
  final detail = outcome.message == null ? '' : ' (${outcome.message})';
  return switch (outcome.result) {
    InstallResult.success => 'Installed.',
    InstallResult.aborted => 'The update was not installed.',
    InstallResult.conflict =>
      'Android refused the update as conflicting with the installed '
          'xtremio$detail. That is what an install from before v0.1.8 gets: '
          'it is signed with a different key. Uninstall xtremio first, then '
          'install the new version; uninstalling removes its login, '
          'settings and downloads.',
    InstallResult.incompatible =>
      'Android says this update does not fit this device$detail.',
    InstallResult.invalid =>
      'Android could not read the downloaded APK$detail.',
    InstallResult.storage => 'There is not enough space to install the update.',
    InstallResult.blocked =>
      'Something on this device blocked the install$detail. Play Protect '
          'or a device policy can do this.',
    InstallResult.failure => 'The install failed$detail.',
  };
}
