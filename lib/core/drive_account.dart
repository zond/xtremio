import 'package:flutter/widgets.dart';

import 'diagnostics_log.dart';
import 'drive_link.dart';
import 'prefs_client.dart';
import 'secret_store.dart';

/// What this device's Google Drive pairing amounts to, as one of three
/// answers.
///
/// Three and not two, because "the token is gone" and "the token is no
/// good" are answered differently by the viewer: one is a pairing that has
/// never happened, the other is a pairing that has to happen again. And
/// three and not four: a request that failed because the television is off
/// the network is not in here at all. **Nothing transient reaches this
/// enum** -- it is derived from what is stored, it is read synchronously,
/// and it is never thrown, so a caller cannot mistake a timeout for
/// [pairAgain] by handling an error badly.
enum DriveLinkState {
  /// Nobody has paired this device, or the last pairing was undone
  /// ([DriveAccount.unlink]). Nothing is stored and nothing is reachable.
  unlinked,

  /// A refresh token is held and nothing has said it is bad. Whether the
  /// *next* request works is a question for the network; this is only the
  /// statement that there is a credential to try.
  linked,

  /// The pairing service answered `pairAgain` for the stored token: it has
  /// been revoked or expired, and no amount of retrying will change that
  /// -- the viewer has to pair from their phone again. The list of linked
  /// files survives, because those files are still the ones a new token
  /// will reach.
  pairAgain,
}

/// What [DriveAccount.link] managed to do with the token it was given.
enum DriveLinkOutcome {
  /// It is in the platform's secure store and will be there after a
  /// restart.
  stored,

  /// The secure store would not open, so the token is held in memory for
  /// this run only and the viewer will have to pair again after a restart.
  /// See [DriveAccount], "When the store will not open".
  thisRunOnly,
}

/// The one Drive pairing this device has: the refresh token, where the
/// files it reaches are written down, and which of [DriveLinkState] the
/// rest of the feature is looking at.
///
/// **One token, not one per file.** The token is a live credential to the
/// viewer's Drive: it does not expire on its own and it reaches every file
/// that account has picked through this OAuth client -- grants accumulate
/// per user and per client, and a token from a second pairing was measured
/// reading a file picked during the first. So there is one secret here,
/// [refreshTokenKey], replaced by each new pairing, and one list of files
/// beside it in the preferences.
///
/// That is also why there is no "unlink one file". Taking a row out of the
/// list would remove a file from a screen while the token still read it
/// byte for byte, which is a screen telling the viewer something untrue.
/// [unlink] is the whole account, and it is the only thing here that
/// removes the credential.
///
/// **When the store will not open.** A Linux box with no keyring daemon
/// has no secure store at all (see [SecureStorageSecretStore]), a keystore
/// entry restored onto another device by Android's backup cannot be
/// decrypted, and a widget test has no platform channel. None of those is
/// worth taking the app down for, and none of them is worth putting the
/// token in the preferences file instead -- so the store failing is
/// handled the way [AppPrefs] handles a failed write: the value is kept in
/// memory and the choice holds for this run. A read that fails reads as
/// "nothing stored", which is [DriveLinkState.unlinked], and the worst it
/// costs is a pairing the viewer does again. A write that fails is
/// [DriveLinkOutcome.thisRunOnly], which the pairing screen can say out
/// loud, and the token never touches a disk it cannot be encrypted on.
///
/// **Nothing here logs the token.** No method writes it to
/// [DiagnosticsLog], and the lines that report a store failure carry the
/// *type* of what was thrown and never the exception's own text, so a
/// platform that puts the value it was handed into an error message cannot
/// leak it through a log line either. The report's scrub is the second
/// lock and knows [refreshTokenKey] by name (`redactSecrets`).
class DriveAccount extends ChangeNotifier {
  DriveAccount({required this.prefs, this.secrets, this.now = DateTime.now});

  /// Where the half of this that is not secret lives: which files are
  /// linked, and whether the token has been rejected.
  final AppPrefs prefs;

  /// Where the token goes. Null keeps it in memory for the run, which is
  /// what a test that does not care about the platform wants.
  final SecretStore? secrets;

  /// The clock a link is stamped from, so a test can pin the moment
  /// instead of asserting about "now" ([ImageDiskCache] takes one for the
  /// same reason).
  final DateTime Function() now;

  /// The key the refresh token is stored under.
  ///
  /// Hyphenated, and that is not a style choice. `redactSecrets` matches
  /// `refresh[_-]?token` on a word boundary, so a line that wrote this key
  /// beside its value comes out of the report as
  /// `drive-refresh-token: <redacted>` -- while `driveRefreshToken` would
  /// have gone through whole, there being no boundary in front of the `R`
  /// for the pattern to start at. Nothing here writes the token into a
  /// line, but the second lock is worth having a name it can catch.
  static const String refreshTokenKey = 'drive-refresh-token';

  String? _refreshToken;
  bool _thisRunOnly = false;
  bool _loaded = false;

  /// Whether [load] has finished. A screen built before it has may draw a
  /// wait rather than "nothing linked yet", which is an answer this cannot
  /// give until the store has been asked once.
  bool get loaded => _loaded;

  /// Which of the three this device is in. Synchronous and free: the token
  /// is held in memory after [load] and the other half is already in the
  /// preferences, so a screen may read this in `build`.
  DriveLinkState get state {
    if (prefs.driveTokenDead) return DriveLinkState.pairAgain;
    return _refreshToken == null
        ? DriveLinkState.unlinked
        : DriveLinkState.linked;
  }

  /// The refresh token to send to the pairing service, or null in either
  /// of the other two states -- a token that has been answered `pairAgain`
  /// is never handed out again, whatever is still in memory.
  ///
  /// **Never log this, never put it in a URL path, never return it over
  /// the FFI** (`AGENTS.md`, "Never log auth material"): it is a live
  /// credential to somebody's Drive and it does not expire on its own.
  String? get refreshToken =>
      state == DriveLinkState.linked ? _refreshToken : null;

  /// Which files this pairing reaches, most recently linked first. Kept in
  /// the preferences, so this is a memory read too.
  LinkedDriveFiles get files => prefs.driveLinkedFiles;

  /// The token is held for this run only, because the secure store would
  /// not take it ([DriveLinkOutcome.thisRunOnly]). Worth saying on the
  /// screen: the pairing works now and will be gone after a restart.
  bool get thisRunOnly => _thisRunOnly;

  /// Reads the stored token. Called once at start-up, **after**
  /// `AppPrefs.load` -- the state is half this and half the preferences,
  /// and reading this half first would answer [DriveLinkState.unlinked]
  /// for an install that is linked.
  ///
  /// A store that throws is a store with nothing in it as far as this is
  /// concerned: there is no way to tell "no keyring on this machine" from
  /// "no token stored" that the viewer could act on differently, and both
  /// end at the same pairing screen.
  Future<void> load() async {
    final store = secrets;
    if (store == null) {
      _loaded = true;
      return;
    }
    String? token;
    try {
      token = await store.read(refreshTokenKey);
    } catch (error) {
      // The type and nothing else: see the class comment.
      DiagnosticsLog.warn(
        'drive',
        'secure store could not be read (${error.runtimeType}); '
            'treating the pairing as absent',
      );
    }
    _loaded = true;
    if (token == null || token.isEmpty) {
      notifyListeners();
      return;
    }
    _refreshToken = token;
    notifyListeners();
  }

  /// Stores [refreshToken] as this device's credential and, when the
  /// pairing named one, writes [file] into the list.
  ///
  /// The token is written first and the list second, so nothing can leave
  /// a list of files behind with no credential to open them. The dead flag
  /// is cleared: a fresh token is exactly what [DriveLinkState.pairAgain]
  /// was waiting for.
  ///
  /// [file] is null when a pairing hands back only a rotated token and
  /// picks no new file.
  Future<DriveLinkOutcome> link({
    required String refreshToken,
    LinkedDriveFile? file,
  }) async {
    final outcome = await _store(refreshToken);
    _refreshToken = refreshToken;
    if (file != null) {
      await prefs.setDriveLinkedFiles(prefs.driveLinkedFiles.linking(file));
    }
    await prefs.setDriveTokenDead(false);
    notifyListeners();
    return outcome;
  }

  /// [link], with the file described the way the pairing service describes
  /// it and the moment stamped from this account's clock.
  Future<DriveLinkOutcome> linkFile({
    required String refreshToken,
    required String fileId,
    required String name,
    required String mimeType,
  }) => link(
    refreshToken: refreshToken,
    file: LinkedDriveFile(
      fileId: fileId,
      name: name,
      mimeType: mimeType,
      linkedAt: now().toUtc(),
    ),
  );

  /// Records that the service answered `pairAgain` for the stored token.
  ///
  /// The credential is removed as well as flagged. A refresh token the
  /// service has rejected opens nothing, so keeping it would be keeping a
  /// credential for no reason; the flag is what carries the state, and it
  /// is the flag and not the absence that [state] reads, so this stays
  /// apart from [DriveLinkState.unlinked] even on a device where the
  /// delete could not happen.
  ///
  /// The list of files is untouched. Those files are still what a new
  /// pairing will reach, and the viewer is owed the list they built.
  Future<void> notePairAgain() async {
    _refreshToken = null;
    _thisRunOnly = false;
    await _forget();
    await prefs.setDriveTokenDead(true);
    notifyListeners();
  }

  /// Undoes the pairing: the credential is deleted, the list of files is
  /// cleared and the dead flag with it, leaving
  /// [DriveLinkState.unlinked] -- a device nobody has paired.
  ///
  /// The secret goes first and unconditionally. Clearing the list without
  /// it would leave a live credential to the viewer's Drive on a
  /// television they believe they have unlinked, which is the one failure
  /// this whole class is arranged to prevent.
  Future<void> unlink() async {
    _refreshToken = null;
    _thisRunOnly = false;
    await _forget();
    await prefs.setDriveLinkedFiles(LinkedDriveFiles.empty);
    await prefs.setDriveTokenDead(false);
    notifyListeners();
  }

  /// Writes down which Cinemeta title [fileId] turned out to be, for
  /// whatever comes to match filenames against the catalogue. Does
  /// nothing when that file is not linked.
  Future<void> noteCinemetaId({
    required String fileId,
    required String? cinemetaId,
  }) async {
    final linked = prefs.driveLinkedFiles.withCinemetaId(fileId, cinemetaId);
    if (linked == prefs.driveLinkedFiles) return;
    await prefs.setDriveLinkedFiles(linked);
    notifyListeners();
  }

  /// Puts [token] in the secure store, or keeps it for the run when the
  /// store will not take it.
  Future<DriveLinkOutcome> _store(String token) async {
    final store = secrets;
    if (store == null) {
      _thisRunOnly = true;
      return DriveLinkOutcome.thisRunOnly;
    }
    try {
      await store.write(refreshTokenKey, token);
      _thisRunOnly = false;
      return DriveLinkOutcome.stored;
    } catch (error) {
      DiagnosticsLog.warn(
        'drive',
        'secure store would not take the pairing (${error.runtimeType}); '
            'it lasts until the app closes',
      );
      _thisRunOnly = true;
      return DriveLinkOutcome.thisRunOnly;
    }
  }

  /// Removes the stored token, swallowing a store that will not open: the
  /// caller has already dropped it from memory, and a delete that could
  /// not happen on a device whose store cannot be read is a delete of
  /// something nothing can read either.
  Future<void> _forget() async {
    final store = secrets;
    if (store == null) return;
    try {
      await store.delete(refreshTokenKey);
    } catch (error) {
      DiagnosticsLog.warn(
        'drive',
        'secure store would not drop the pairing (${error.runtimeType})',
      );
    }
  }
}

/// Hands [DriveAccount] down the tree, the way [PrefsScope] hands the
/// preferences down: one per app, and an [InheritedNotifier] so a screen
/// that reads the state rebuilds when a pairing changes it.
class DriveAccountScope extends InheritedNotifier<DriveAccount> {
  const DriveAccountScope({
    super.key,
    required DriveAccount account,
    required super.child,
  }) : super(notifier: account);

  static DriveAccount of(BuildContext context) {
    final account = maybeOf(context);
    assert(account != null, 'No DriveAccountScope above this widget');
    return account!;
  }

  static DriveAccount? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DriveAccountScope>()?.notifier;
}
