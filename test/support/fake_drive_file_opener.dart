import 'package:xtremio/core/core.dart';

/// A [DriveFileOpener] a test drives by hand, and the record of what was
/// handed down to it.
///
/// **Its point is the record.** What matters about this call is not only
/// that a URL comes back but that the grant went in and nowhere else, so
/// [asked] keeps every request as it arrived -- the file id, the token and
/// the name -- and a test asserts over it. Nothing here reaches FFI.
class FakeDriveFileOpener implements DriveFileOpener {
  FakeDriveFileOpener({List<DriveOpened>? answers}) : answers = [...?answers];

  /// What each call answers, in order; the **last** one repeats forever, so
  /// a test can say "this is what opening a file does" without counting the
  /// presses. Empty answers the file's own source URL, as the server does.
  final List<DriveOpened> answers;

  /// Every open that was asked for, in order.
  final List<DriveOpenRequest> asked = [];

  /// While set, every open waits on it before answering: what a test needs
  /// to press again while the server is still being asked.
  Future<void>? pending;

  @override
  Future<DriveOpened> openDriveFile({
    required String fileId,
    required String refreshToken,
    String? name,
  }) async {
    asked.add(
      DriveOpenRequest(fileId: fileId, refreshToken: refreshToken, name: name),
    );
    if (pending != null) await pending;
    if (answers.isEmpty) return fakeDrivePlayable(fileId: fileId, name: name);
    return answers.length == 1 ? answers.first : answers.removeAt(0);
  }
}

/// One ask, exactly as it arrived.
class DriveOpenRequest {
  const DriveOpenRequest({
    required this.fileId,
    required this.refreshToken,
    this.name,
  });

  final String fileId;
  final String refreshToken;
  final String? name;
}

/// What the server would answer with: the file's own source URL, which
/// the player plays by media id, and nothing about the account.
DriveFilePlayable fakeDrivePlayable({
  String fileId = '1AbCdEfGhIjKlMnOpQrStUvWxYz',
  String? name,
}) => DriveFilePlayable(url: Uri.parse('xtremio-drive:$fileId'), name: name);
