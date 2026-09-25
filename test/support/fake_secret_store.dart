import 'package:xtremio/core/core.dart';

/// A [SecretStore] over a map, standing in for the platform's keystore,
/// keychain, credential manager or keyring. Everything written is readable
/// here, and the same instance handed to a second [DriveAccount] is what a
/// fresh app start reads — which is how a test tells "the pairing stuck"
/// from "the object kept it in a field".
///
/// Nothing in it is encrypted, which is the point: a test asserting that
/// the token is *not* somewhere needs to be able to see plainly that it is
/// here.
class FakeSecretStore implements SecretStore {
  FakeSecretStore([Map<String, String>? stored])
    : stored = {...?stored},
      failing = false;

  /// One with no store behind it at all: a Linux box with no keyring
  /// daemon, an Android keystore that will not unwrap its key, a widget
  /// test with no platform channel. Every call throws.
  FakeSecretStore.failing() : stored = {}, failing = true;

  /// What is "in the keyring".
  final Map<String, String> stored;

  final bool failing;

  /// Every key written and every key deleted, in order, so a test can see
  /// that unlinking reached the store rather than only the list.
  final List<String> writes = [];
  final List<String> deletes = [];

  @override
  Future<String?> read(String key) async {
    if (failing) throw StateError('no keyring on this machine');
    return stored[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failing) throw StateError('no keyring on this machine');
    writes.add(key);
    stored[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failing) throw StateError('no keyring on this machine');
    deletes.add(key);
    stored.remove(key);
  }
}
