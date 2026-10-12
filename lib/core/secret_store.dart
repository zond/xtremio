import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where a secret goes: a live credential, which must not be in the
/// preferences file ([AppPrefs]), in the log ring, or in a copied
/// diagnostics report.
///
/// It is an interface for the same reason `PrefsClient` is one: a test hands a
/// map instead of reaching a platform channel. It is also an interface because
/// the one decision this store forces, *what happens when it will not open*,
/// belongs above it ([DriveAccount]) and not in six platform implementations.
///
/// Deliberately three methods and no `readAll`. A caller that can list the
/// secrets is a caller that can log them by accident, and every key here is one
/// this app wrote and already knows the name of.
abstract interface class SecretStore {
  /// The value stored under [key], or null when there is none. Throws when the
  /// store cannot be opened or the value cannot be decrypted. The caller
  /// decides what that means, since "no keyring on this machine" and "nothing
  /// stored" are different facts.
  Future<String?> read(String key);

  /// Stores [value] under [key], replacing what was there.
  Future<void> write(String key, String value);

  /// Removes [key]. Removing one that is not there is not an error.
  Future<void> delete(String key);
}

/// [SecretStore] over `flutter_secure_storage`, which is a *different* store on
/// each platform this app builds for. Here is what each one actually gets,
/// because a store that silently no-ops on one of them would be worse than
/// none:
///
/// - **Android** (the television, and the one that matters): the plugin's own
///   `SharedPreferences` file. Every value in it is AES-GCM ciphertext, and the
///   AES key is wrapped with an RSA-OAEP keypair that lives in the Android
///   Keystore, hardware-backed wherever the device has a TEE or StrongBox. It
///   is the same shape as `EncryptedSharedPreferences` (a preferences file
///   whose values are ciphertext, rooted in the Keystore), but built with the
///   plugin's own ciphers rather than Jetpack Security's deprecated
///   `androidx.security.crypto`. Keystore is a CDD requirement, so an Android
///   TV box has one. No biometric prompt is asked for, which is the point on a
///   device whose only input is a remote. Needs API 23, and this app's `minSdk`
///   is 24.
/// - **macOS**: the Keychain, with the data-protection keychain turned *off*
///   ([MacOsOptions.usesDataProtectionKeychain]). The data-protection keychain
///   wants a `keychain-access-groups` entitlement. That is Keychain Sharing,
///   which needs a provisioning profile, and this project has no Apple
///   Developer Program account and no Mac (`.github/workflows/build.yml`). The
///   legacy keychain wants neither and is still the Keychain: encrypted at
///   rest, unlocked with the login session.
/// - **Windows**: an AES-GCM-encrypted file in the app's support directory,
///   whose key is held in the Windows Credential Manager under the user's
///   account. Building it wants the C++ ATL libraries in the Visual Studio
///   Build Tools.
/// - **Linux**: libsecret, the Secret Service API. That means `gnome-keyring`,
///   KWallet, or another provider, and **it means nothing at all on a machine
///   with no keyring daemon running**. This is the platform where the honest
///   answer is that there may be no secure store here. Every call throws, and
///   [DriveAccount] holds the token in memory for the run rather than
///   pretending. Building wants `libsecret-1-dev`; running wants
///   `libsecret-1-0` and a daemon.
///
/// Web is not built and iOS is not carried (`README.md`, "Building for
/// iOS"), so neither is configured here.
class SecureStorageSecretStore implements SecretStore {
  const SecureStorageSecretStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    // The default ciphers: RSA-OAEP wrapping an AES-GCM key. They are spelled
    // out rather than left implicit, because the constructor is where a future
    // reader looks for two things. One is whether this app asked for
    // biometrics, which it must not (see the class comment). The other is
    // whether the version-9 migration is on. It is, by default, and costs
    // nothing on an install that has never stored anything.
    aOptions: AndroidOptions(),
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
