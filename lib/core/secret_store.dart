import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where a secret goes: a live credential, which must not be in the
/// preferences file ([AppPrefs]), in the log ring, or in a copied
/// diagnostics report.
///
/// An interface for the same reason `PrefsClient` is one -- a test hands a
/// map instead of reaching a platform channel -- and because the one
/// decision this store forces, *what happens when it will not open*,
/// belongs above it ([DriveAccount]) and not in six platform
/// implementations.
///
/// Deliberately three methods and no `readAll`. A caller that can list the
/// secrets is a caller that can log them by accident; every key here is
/// one this app wrote and already knows the name of.
abstract interface class SecretStore {
  /// The value stored under [key], or null when there is none. Throws when
  /// the store cannot be opened or the value cannot be decrypted -- the
  /// caller decides what that means, since "no keyring on this machine"
  /// and "nothing stored" are different facts.
  Future<String?> read(String key);

  /// Stores [value] under [key], replacing what was there.
  Future<void> write(String key, String value);

  /// Removes [key]. Removing one that is not there is not an error.
  Future<void> delete(String key);
}

/// [SecretStore] over `flutter_secure_storage`, which is a *different*
/// store on each platform this app builds for. What each one actually
/// gets, because a store that silently no-ops on one of them would be
/// worse than none:
///
/// - **Android** (the television, and the one that matters): the plugin's
///   own `SharedPreferences` file, every value in it AES-GCM ciphertext,
///   the AES key wrapped with an RSA-OAEP keypair that lives in the
///   Android Keystore and is hardware-backed wherever the device has a
///   TEE or StrongBox. This is what was asked for as
///   `EncryptedSharedPreferences` and is the same shape -- a preferences
///   file whose values are ciphertext, rooted in the Keystore -- but it is
///   not Jetpack Security's class: version 10 of the plugin dropped
///   `androidx.security.crypto`, which Google has deprecated and no longer
///   maintains, for ciphers of its own. Keystore is a CDD requirement, so
///   an Android TV box has one; no biometric prompt is asked for, which is
///   the point on a device whose only input is a remote. Needs API 23, and
///   this app's `minSdk` is 24.
/// - **macOS**: the Keychain, with the data-protection keychain turned
///   *off* ([MacOsOptions.usesDataProtectionKeychain]). The
///   data-protection keychain wants a `keychain-access-groups`
///   entitlement, which is Keychain Sharing, which needs a provisioning
///   profile -- and this project has no Apple Developer Program account
///   and no Mac (`.github/workflows/build.yml`). The legacy keychain wants
///   neither and is still the Keychain: encrypted at rest, unlocked with
///   the login session.
/// - **Windows**: an AES-GCM-encrypted file in the app's support
///   directory, whose key is held in the Windows Credential Manager under
///   the user's account. Building it wants the C++ ATL libraries in the
///   Visual Studio Build Tools.
/// - **Linux**: libsecret, which is the Secret Service API -- which means
///   `gnome-keyring`, KWallet, or another provider, and **means nothing at
///   all on a machine with no keyring daemon running**. This is the
///   platform where the honest answer is that there may be no secure store
///   here: every call throws, and [DriveAccount] holds the token in memory
///   for the run rather than pretending. Building wants
///   `libsecret-1-dev`; running wants `libsecret-1-0` and a daemon.
///
/// Web is not built and iOS is not carried (`README.md`, "Building for
/// iOS"), so neither is configured here.
class SecureStorageSecretStore implements SecretStore {
  const SecureStorageSecretStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    // The default ciphers: RSA-OAEP wrapping an AES-GCM key. Spelled out
    // rather than left implicit, because the constructor is where a future
    // reader looks for whether this app asked for biometrics (it must not
    // -- see the class comment) and for whether the version-9 migration is
    // on (it is, by default, and costs nothing on an install that has
    // never stored anything).
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
