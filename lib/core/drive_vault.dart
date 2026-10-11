/// The Drive grant shared between the account's devices, through
/// xtremio-xervice's vault.
///
/// Pairing a device with Drive is a phone, a QR code and a Google sign-in,
/// and the grant it ends with reaches every file that Google account ever
/// picked through this OAuth client. So the grant is put in the account's
/// vault (`PUT /vault/drive`, sealed at rest with the service's `GRANT_KEY`,
/// `xtremio-xervice/functions/account.js`) after a pairing, and a device of
/// the same Stremio account with no grant of its own takes it from there
/// (`GET`) at start and at a sign-in, through [DriveAccount.adoptSharedGrant]
/// -- the same store, the same `grantSink` to Rust, as a pairing.
///
/// **The device's own grant wins.** A device that holds one never takes
/// the vault's, which may be older or another Google account's. The
/// device's secure store stays the primary copy and the vault a copy of
/// the latest pairing -- only a pairing writes it, so a grant forgotten
/// everywhere is not put back by a device that still holds one.
///
/// **The files come with it.** A grant taken from the vault reaches every
/// file the Google account picked through this client, so the device lists
/// them ([adopted]) rather than starting with an empty list.
///
/// **Never logged.** The token rides one request body or one answer and
/// nothing here writes a line with it; a failure is logged by status.
library;

import 'diagnostics_log.dart';
import 'drive_account.dart';
import 'xervice_identity.dart';

class DriveVault {
  DriveVault({required this.identity, required this.account, this.adopted});

  final XerviceIdentity identity;
  final DriveAccount account;

  /// Run once a grant from the vault is installed: what fills the device's
  /// list with the files the grant reaches, and matches them
  /// (`fillSharedDrive`). Null installs the grant and nothing else.
  final Future<void> Function()? adopted;

  /// Puts [refreshToken] -- a pairing's -- in the account's vault.
  Future<void> store(String refreshToken) async {
    final answer = await identity.send(
      'PUT',
      '/vault/drive',
      body: {'refreshToken': refreshToken},
    );
    if (answer != null && !answer.ok) {
      DiagnosticsLog.info(
        'drive',
        'vault would not keep the grant '
            '(${answer.status})',
      );
    }
  }

  /// At start and at a sign-in: a device with no grant takes the vault's.
  /// One that has a grant, or whose grant Google refused, asks nothing.
  Future<void> reconcile() async {
    if (!identity.signedIn) return;
    if (account.state != DriveLinkState.unlinked) return;
    final answer = await identity.send('GET', '/vault/drive');
    if (answer == null || answer.status == 404) return;
    final token = answer.json?['refreshToken'];
    if (!answer.ok || token is! String || token.isEmpty) {
      DiagnosticsLog.info('drive', 'vault not read (${answer.status})');
      return;
    }
    // Which asks again: a pairing that landed while the answer was out is
    // this device's own, and it wins.
    await account.adoptSharedGrant(token);
    // Only when it took: a device that paired meanwhile keeps its own list.
    if (account.refreshToken == token) await adopted?.call();
  }

  /// Forgets the grant on the account, so no device takes it again.
  /// Answers whether the service heard it. The grant itself lives on with
  /// Google until it is revoked there, and on every device that holds it.
  Future<bool> forgetEverywhere() async {
    final answer = await identity.send('DELETE', '/vault/drive');
    return answer != null && answer.ok;
  }
}
