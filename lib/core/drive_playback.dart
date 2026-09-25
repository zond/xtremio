/// Turning a linked Google Drive file into something the player can open.
///
/// A [LinkedDriveFile] is a name and an id; a player wants a URL. The one
/// thing that can make the second out of the first is the embedded
/// streaming server, which holds the file as a byte source and renews the
/// account's access token for itself -- so this is the ask, and
/// [openLinkedDriveFile] is the whole of the flow.
///
/// **The grant crosses one boundary and no more.** The refresh token comes
/// out of the secure store through [DriveAccount.refreshToken], goes
/// straight into the FFI call, and is spent inside the server's own
/// process. It is in no URL, no log line and no exception here: what comes
/// back is a loopback URL naming a random key -- not the account, and not
/// even the file id -- which is why the string that reaches mpv, the
/// diagnostics log and a copied bug report says nothing about either.
/// [DriveOpenFailure] is a word rather than a sentence for the same
/// reason.
///
/// **A dead pairing is written down here, once.** The server answers
/// `pairAgain` when the grant is gone, which is terminal -- no retry brings
/// it back, only a new QR -- so [openLinkedDriveFile] calls
/// [DriveAccount.notePairAgain] on the way past. The account's state
/// becomes [DriveLinkState.pairAgain], every screen that reads it redraws,
/// and the credential is dropped: nothing else has to remember to do any of
/// that, and nothing gets to decide differently.
library;

import 'dart:convert';

import '../src/rust/api/server.dart' as rust;
import 'drive_account.dart';
import 'drive_link.dart';

/// Why a linked file could not be played. Each is drawn differently, which
/// is why they are separate and why none of them is a sentence from
/// somewhere else.
enum DriveOpenFailure {
  /// **Terminal.** The grant has been revoked or has expired and the
  /// pairing service said so. The viewer pairs again from their phone; the
  /// list of files survives, because those files are what a new token will
  /// reach.
  pairAgain,

  /// Nothing is stored for this device to open anything with: nobody has
  /// paired, or the pairing was undone. Not a failure of this call -- the
  /// caller asked with no credential.
  notLinked,

  /// This build has no pairing service configured, so there is nothing to
  /// renew a token against. A fact about the build; a viewer can do nothing
  /// with it.
  noPairingService,

  /// Google or the pairing service could not be reached, or would not serve
  /// the file by range. Worth trying again; the grant may be perfectly
  /// good.
  unreachable,

  /// The embedded server is not running, so nothing could be opened. Not
  /// about the account either.
  unavailable,

  /// The server answered something this build cannot read. Kept apart from
  /// [unreachable] because it means a version skew rather than a network.
  notUnderstood,
}

/// What [DriveFileOpener.open] answers: a URL, or the reason there is none.
sealed class DriveOpened {
  const DriveOpened();
}

/// The file is open and these are its bytes.
final class DriveFilePlayable extends DriveOpened {
  const DriveFilePlayable({
    required this.url,
    this.name,
    this.contentType,
    this.length,
  });

  /// Where the player fetches the film: the embedded server's
  /// `/drive/stream/{key}`. **Carries no credential**, which is why it is
  /// safe to hand to mpv, to a log and to a bug report.
  final Uri url;

  /// What Drive calls the file, as the server echoed it back.
  final String? name;

  /// What Drive labelled the bytes (`video/x-matroska`).
  final String? contentType;

  /// How long the file is, in bytes.
  final int? length;
}

/// It could not be opened, and this is which of the reasons.
final class DriveFileRefused extends DriveOpened {
  const DriveFileRefused(this.reason);

  final DriveOpenFailure reason;
}

/// Asking the embedded server to open a file in the paired Drive.
///
/// Behind an interface so the pairing screen's widget tests can play a file
/// without reaching FFI, and so a test can say which id and which token
/// were handed over -- the second of which is the one thing about this that
/// has to be checked rather than assumed.
abstract interface class DriveFileOpener {
  /// Opens [fileId] under [refreshToken] and answers a URL or a reason.
  /// **Never throws for a server that is not running**: that is
  /// [DriveOpenFailure.unavailable], so every outcome is a value the caller
  /// can draw.
  Future<DriveOpened> openDriveFile({
    required String fileId,
    required String refreshToken,
    String? name,
  });
}

/// [DriveFileOpener] over the embedded server's FFI (`server_drive_open`).
class ServerDriveFileOpener implements DriveFileOpener {
  const ServerDriveFileOpener();

  @override
  Future<DriveOpened> openDriveFile({
    required String fileId,
    required String refreshToken,
    String? name,
  }) async {
    final String answer;
    try {
      answer = await rust.serverDriveOpen(
        fileId: fileId,
        refreshToken: refreshToken,
        name: name,
      );
    } on Object {
      // A panic in the core, or a bridge that is not up. The exception's
      // own text is not shown and not logged: the call it came out of was
      // handed the grant, and a habit of printing what an exception said
      // is how the one that carries it gets filed (`AGENTS.md`, "Never log
      // auth material").
      return const DriveFileRefused(DriveOpenFailure.unavailable);
    }
    return parseDriveOpenAnswer(answer);
  }
}

/// The server's `server_drive_open` JSON as one of the two outcomes.
///
/// Visible for tests, and shaped so that anything it does not recognise is
/// [DriveOpenFailure.notUnderstood] rather than a throw: a build reading an
/// answer from a newer core has a sentence to draw instead of a crash.
DriveOpened parseDriveOpenAnswer(String answer) {
  final Object? json;
  try {
    json = jsonDecode(answer);
  } on FormatException {
    return const DriveFileRefused(DriveOpenFailure.notUnderstood);
  }
  if (json is! Map) {
    return const DriveFileRefused(DriveOpenFailure.notUnderstood);
  }
  if (json['ok'] == true) {
    final url = json['url'];
    final parsed = url is String ? Uri.tryParse(url) : null;
    // A success with no URL in it is not a success. It cannot happen from
    // the core this ships with, and answering `notUnderstood` is what keeps
    // it from becoming a null dereference in a player if it ever does.
    if (parsed == null) {
      return const DriveFileRefused(DriveOpenFailure.notUnderstood);
    }
    final name = json['name'];
    final contentType = json['contentType'];
    final length = json['length'];
    return DriveFilePlayable(
      url: parsed,
      name: name is String && name.isNotEmpty ? name : null,
      contentType: contentType is String && contentType.isNotEmpty
          ? contentType
          : null,
      length: length is int ? length : null,
    );
  }
  return DriveFileRefused(switch (json['reason']) {
    'pairAgain' => DriveOpenFailure.pairAgain,
    'noPairingService' => DriveOpenFailure.noPairingService,
    'unreachable' => DriveOpenFailure.unreachable,
    'unavailable' => DriveOpenFailure.unavailable,
    _ => DriveOpenFailure.notUnderstood,
  });
}

/// Opens [file] with the account's own credential, and records a dead
/// pairing on the way past.
///
/// The account is asked for the token rather than given one: [file] is a
/// row in a list, and which credential reaches it is [DriveAccount]'s
/// business alone -- it already refuses to hand out a token the service has
/// rejected, whatever is still in memory. No token is returned, held, or
/// put anywhere a caller could reach it.
///
/// A `pairAgain` answer calls [DriveAccount.notePairAgain] before it
/// returns, so the state every screen reads is already
/// [DriveLinkState.pairAgain] by the time the caller draws anything. That
/// is the one side effect here, and it is here rather than in a caller
/// because a second caller that forgot it would leave a television offering
/// films it can no longer read.
Future<DriveOpened> openLinkedDriveFile({
  required DriveAccount account,
  required LinkedDriveFile file,
  required DriveFileOpener opener,
}) async {
  final token = account.refreshToken;
  if (token == null || token.isEmpty) {
    return const DriveFileRefused(DriveOpenFailure.notLinked);
  }
  final opened = await opener.openDriveFile(
    fileId: file.fileId,
    refreshToken: token,
    name: file.name,
  );
  if (opened is DriveFileRefused &&
      opened.reason == DriveOpenFailure.pairAgain) {
    await account.notePairAgain();
  }
  return opened;
}

/// The raw stream JSON a `PlayerScreen` is given for a Drive file.
///
/// The shape stremio-core's `Stream` parses, hand-built, exactly as the
/// developer play tiles are (`DevStreams`): a `url`, which is what makes it
/// a `StreamKind.url` the engine plays directly. It is on the embedded
/// server already, so `proxiedThroughServer` leaves it alone and nothing
/// wraps a loopback URL in a second hop.
///
/// **What the player is given as a title is the file's own name**, because
/// it is the only true thing anybody knows. A Drive file has no addon, no
/// `StreamInfo` from the core and no metadata: nothing has matched it
/// against Cinemeta, so there is no title, no poster and no episode. The
/// player's overlay shows `PlayerState.title`, which with no meta item
/// falls through to the stream's own `name` -- so `name` is what the
/// viewer's Drive calls the file, which is a thing a person recognises,
/// and `description` says where it came from. Putting "Google Drive" in
/// `name` instead would draw the source where the film's name belongs and
/// leave five linked files looking identical on screen.
///
/// `behaviorHints.filename` is the same name and is not decoration: the
/// stream URL is `/drive/stream/{key}` with no extension on it, and the
/// cast check reads the container off a filename or refuses the cast
/// outright (`castFilename`, `CastCompatibility`). The name is Drive's own
/// and carries the real suffix.
Map<String, dynamic> driveStreamJson({
  required LinkedDriveFile file,
  required DriveFilePlayable playable,
}) {
  final name = playable.name ?? file.name;
  return {
    'url': playable.url.toString(),
    'name': name.isEmpty ? driveSourceLabel : name,
    'description': driveSourceLabel,
    if (name.isNotEmpty) 'behaviorHints': {'filename': name},
  };
}

/// What a Drive stream says it came from, on the player and in a list.
const String driveSourceLabel = 'Google Drive';

/// What a viewer is told about [reason]. One sentence each, written here so
/// that nothing downstream has to invent one and nothing echoes an error.
String driveFailureMessage(DriveOpenFailure reason) => switch (reason) {
  DriveOpenFailure.pairAgain =>
    'This device is no longer linked to that Google account. Link it again '
        'to play your files.',
  DriveOpenFailure.notLinked =>
    'No Google account is linked to this device yet.',
  DriveOpenFailure.noPairingService =>
    'This build cannot keep a Google Drive link alive. Nothing you can do '
        'about it from here.',
  DriveOpenFailure.unreachable =>
    'Google could not be reached just now. Try again in a moment.',
  DriveOpenFailure.unavailable =>
    'The streaming server is not running, so there is nothing to play this '
        'through.',
  DriveOpenFailure.notUnderstood =>
    'The streaming server answered something this app could not read.',
};
