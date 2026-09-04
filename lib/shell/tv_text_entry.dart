import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_profile.dart';

/// What a field wants typed into it, as far as the keyboard cares.
enum TvTextKind {
  text,
  email,
  password,
  url;

  /// The keyboard the ordinary Flutter field asks for off a television.
  TextInputType get keyboardType => switch (this) {
    TvTextKind.text => TextInputType.text,
    TvTextKind.email => TextInputType.emailAddress,
    // Not [TextInputType.visiblePassword]: that is the *shown* password
    // keyboard, and this field is obscured.
    TvTextKind.password => TextInputType.text,
    TvTextKind.url => TextInputType.url,
  };

  /// Masked on screen, and kept out of autofill and out of whatever the
  /// keyboard learns from what is typed into it.
  bool get isSecret => this == TvTextKind.password;

  /// Autocorrect belongs to prose only; an address of any kind is not it.
  bool get autocorrects => this == TvTextKind.text;
}

/// Text typed on a screen of the platform's own, because a television
/// cannot type on ours.
///
/// On Android TV the app window keeps input focus while the on-screen
/// keyboard is up, so every D-pad press is delivered to Flutter and moves
/// Flutter's focus: the keyboard can never move its own selection and is
/// decorative. What makes the difference is `IME_FLAG_NO_FULLSCREEN`, which
/// Flutter sets on every field it creates and which Dart cannot unset —
/// fullscreen ("extract") mode is exactly the mode in which the keyboard
/// takes focus and owns the remote.
///
/// So the field is not hosted here at all. [edit] asks `MainActivity` for a
/// one-field screen of its own (`TextEntryActivity.kt`), whose `EditText`
/// carries no such flag, and takes back the string it was left with.
/// [TvTextField] is the only caller; nothing else should need this.
abstract final class TvTextEntry {
  /// The method `MainActivity` answers on [DeviceProfile.channel].
  static const String method = 'editText';

  /// Opens the platform's text-entry screen on [value] and answers with
  /// what it was left holding: the finished string, or null when it was
  /// cancelled.
  ///
  /// Null is also the answer where there is no such screen (every platform
  /// but Android) and when the call fails, so a caller that gets null
  /// leaves its value exactly as it was, always.
  static Future<String?> edit({
    required String label,
    required String value,
    required TvTextKind kind,
    MethodChannel channel = DeviceProfile.channel,
  }) async {
    try {
      return await channel.invokeMethod<String>(method, <String, Object?>{
        'label': label,
        'value': value,
        'kind': kind.name,
      });
    } on PlatformException catch (error) {
      // The code and nothing else: a password field's value went out in
      // this call, and a platform message can quote what it was given.
      if (kDebugMode) debugPrint('text entry unavailable: ${error.code}');
      return null;
    } on MissingPluginException {
      if (kDebugMode) debugPrint('text entry unavailable: no platform side');
      return null;
    }
  }
}
