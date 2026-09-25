/// Picking Google Drive files with Android's own picker, rather than with
/// the web one.
///
/// **Why there are two pickers at all.** The web Google Picker cannot select
/// more than one file on a phone: it gates selection on a Ctrl/Cmd key, so a
/// device with no keyboard holds exactly one
/// (issuetracker.google.com/issues/334994030, reported April 2024, still
/// open). The native Android picker can, measured at seven files in one go.
/// So a phone with this app installed picks here, and a phone without it
/// still gets the web page — which is why that page stays exactly as it is.
///
/// The parameter that turns an authorization into a picker is spelled
/// `trigger_onepick` on the wire, which is the *same* parameter the web flow
/// is refused for. That is not a contradiction and it is worth writing down:
/// what refuses it there is Google's legacy consent page, which a web client
/// is routed to. The native path never goes near that page.
///
/// **The code that comes back is for the web client, on purpose.** A
/// `drive.file` grant is recorded against a user *and a client*, and the
/// television reads with a token minted from the web client's secret — so a
/// pick recorded against this app's own Android client would grant the
/// television nothing at all. Asking for offline access while naming the web
/// client is what puts the grant where it can be used.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What a native pick produced.
@immutable
sealed class DriveNativePickResult {
  const DriveNativePickResult();
}

/// The viewer signed in and chose files.
///
/// [serverAuthCode] is a **credential**: one-time, short-lived, and
/// exchangeable by the pairing service into the refresh token a television
/// keeps. It is carried in one field of one object and put in no log line
/// and on no screen, the same rule the pairing answer follows.
@immutable
final class DriveNativePicked extends DriveNativePickResult {
  const DriveNativePicked({
    required this.serverAuthCode,
    required this.fileIds,
  });

  final String serverAuthCode;

  /// Drive's ids for what was chosen, in the order the picker gave them.
  /// Ids only: the names are read by the service with the credential it
  /// mints, because a name is drawn on a television and matched against a
  /// catalogue, and is not a thing a client should invent about somebody
  /// else's Drive.
  final List<String> fileIds;

  /// Names nothing that is a secret. The code's *length* is as much as is
  /// ever said about it, which is enough to tell "a code came back" from
  /// "an empty code came back" and nothing more.
  @override
  String toString() =>
      'DriveNativePicked(${fileIds.length} files, code ${serverAuthCode.length} chars)';
}

/// The viewer backed out, or chose nothing. Not an error and not worth a
/// message: they know what they did.
@immutable
final class DriveNativePickCancelled extends DriveNativePickResult {
  const DriveNativePickCancelled();
}

/// This device cannot pick natively — not Android, or no Play services, or
/// a Play services too old to know the picker. The caller's answer to this
/// is the web page, which is where every other phone already goes.
@immutable
final class DriveNativePickUnavailable extends DriveNativePickResult {
  const DriveNativePickUnavailable();
}

/// It was tried and it broke. [reason] is for a viewer to read, so it says
/// what happened rather than which exception carried it.
@immutable
final class DriveNativePickFailed extends DriveNativePickResult {
  const DriveNativePickFailed(this.reason);

  final String reason;

  @override
  String toString() => 'DriveNativePickFailed($reason)';
}

/// Runs the native picker. An interface because the screen that drives it is
/// walked by a widget test, and a test must not reach a platform channel.
abstract interface class DriveNativePicker {
  /// Whether this build can pick natively at all, answered without opening
  /// anything. Cheap, so a caller may ask before drawing a choice.
  Future<bool> available();

  /// Signs in, shows the picker, and comes back with what was chosen.
  Future<DriveNativePickResult> pick();
}

/// [DriveNativePicker] over the Android side (`DrivePicker.kt`).
class MethodChannelDriveNativePicker implements DriveNativePicker {
  const MethodChannelDriveNativePicker();

  /// The one channel, named for what it does rather than for the library it
  /// happens to use.
  static const MethodChannel channel = MethodChannel('xtremio/drive_picker');

  @override
  Future<bool> available() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await channel.invokeMethod<bool>('available') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // A desktop or iOS build has no such channel, and asking is not an
      // error there — it is the answer.
      return false;
    }
  }

  @override
  Future<DriveNativePickResult> pick() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const DriveNativePickUnavailable();
    }
    try {
      final answer = await channel.invokeMapMethod<String, Object?>('pick');
      if (answer == null) return const DriveNativePickCancelled();
      final code = answer['serverAuthCode'];
      final ids = [
        for (final id in (answer['fileIds'] as List<Object?>? ?? const []))
          if (id is String && id.isNotEmpty) id,
      ];
      // Both halves or neither. A pick with files and no code is a pairing
      // the television could never open, and a code with no files is a
      // credential minted for nothing — either alone is a worse outcome than
      // saying it did not work.
      if (code is! String || code.isEmpty || ids.isEmpty) {
        return const DriveNativePickCancelled();
      }
      return DriveNativePicked(serverAuthCode: code, fileIds: ids);
    } on PlatformException catch (error) {
      return switch (error.code) {
        'cancelled' => const DriveNativePickCancelled(),
        'unavailable' => const DriveNativePickUnavailable(),
        // `error.message` is Google's, and Google's messages here name
        // statuses and not secrets. The code is never in it: this side
        // never sends one and the Android side never puts one in a message.
        _ => DriveNativePickFailed(error.message ?? error.code),
      };
    } on MissingPluginException {
      return const DriveNativePickUnavailable();
    }
  }
}
