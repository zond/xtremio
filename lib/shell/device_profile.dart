import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What kind of device the app is running on, as far as the UI cares: a
/// television driven by a remote (D-pad focus, no pointer, 10-foot sizes)
/// or not, and whether there is a touchscreen at all.
///
/// Resolved once at start-up by [DeviceProfile.detect] and handed down the
/// tree through [DeviceScope]; nothing reads the platform again later.
@immutable
class DeviceProfile {
  const DeviceProfile({required this.isTv, required this.hasTouch});

  /// What every screen assumes without a [DeviceScope] above it, and what
  /// detection falls back to: the phone/desktop layout the app has always
  /// had. Not a TV, and touch is allowed for (a mouse works everywhere a
  /// touch does).
  static const DeviceProfile fallback = DeviceProfile(
    isTv: false,
    hasTouch: true,
  );

  /// A television or set-top box: Android TV / Google TV, driven by a
  /// remote. Layouts go wide, targets grow, and focus is the way around.
  final bool isTv;

  /// The device has a touchscreen. False on a TV box and on desktops.
  final bool hasTouch;

  /// The platform channel the Android side answers on (`MainActivity.kt`).
  static const MethodChannel channel = MethodChannel('xtremio/device');

  /// Asks the platform which device this is.
  ///
  /// Only Android has anything to say: `MainActivity` answers `profile`
  /// with `isTv` (`UiModeManager` reports television mode, or the leanback
  /// feature is present) and `hasTouch` (`FEATURE_TOUCHSCREEN`). Every
  /// other platform resolves locally without a channel call — a desktop is
  /// never a TV and has no touchscreen, iOS is a touch device. A channel
  /// that is missing or throws yields [fallback]; a TV mistaken for a
  /// phone is still usable, the reverse is not.
  static Future<DeviceProfile> detect({
    MethodChannel channel = DeviceProfile.channel,
    TargetPlatform? platform,
  }) async {
    switch (platform ?? defaultTargetPlatform) {
      case TargetPlatform.android:
        break;
      case TargetPlatform.iOS:
        return const DeviceProfile(isTv: false, hasTouch: true);
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return const DeviceProfile(isTv: false, hasTouch: false);
    }
    try {
      final reply = await channel.invokeMapMethod<String, Object?>('profile');
      if (reply == null) return fallback;
      return DeviceProfile(
        isTv: reply['isTv'] as bool? ?? fallback.isTv,
        hasTouch: reply['hasTouch'] as bool? ?? fallback.hasTouch,
      );
    } on PlatformException catch (error) {
      if (kDebugMode) debugPrint('device profile unavailable: $error');
      return fallback;
    } on MissingPluginException catch (error) {
      if (kDebugMode) debugPrint('device profile unavailable: $error');
      return fallback;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceProfile &&
      other.isTv == isTv &&
      other.hasTouch == hasTouch;

  @override
  int get hashCode => Object.hash(isTv, hasTouch);

  @override
  String toString() => 'DeviceProfile(isTv: $isTv, hasTouch: $hasTouch)';
}

/// Provides the [DeviceProfile] to the widget tree. `XtremioApp` creates
/// one from what start-up detected; a widget without a scope above it (a
/// test harness that does not care) gets [DeviceProfile.fallback], so
/// wrapping in `DeviceScope(profile: DeviceProfile(isTv: true, ...))` is
/// how a test puts a screen on a television.
class DeviceScope extends InheritedWidget {
  const DeviceScope({super.key, required this.profile, required super.child});

  final DeviceProfile profile;

  static DeviceProfile of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeviceScope>()?.profile ??
      DeviceProfile.fallback;

  /// Shorthand for `DeviceScope.of(context).isTv`.
  static bool isTv(BuildContext context) => of(context).isTv;

  @override
  bool updateShouldNotify(DeviceScope oldWidget) =>
      profile != oldWidget.profile;
}
