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
  /// presses. Empty answers a URL on the loopback server.
  final List<DriveOpened> answers;

  /// Every open that was asked for, in order.
  final List<DriveOpenRequest> asked = [];

  @override
  Future<DriveOpened> openDriveFile({
    required String fileId,
    required String refreshToken,
    String? name,
  }) async {
    asked.add(
      DriveOpenRequest(fileId: fileId, refreshToken: refreshToken, name: name),
    );
    if (answers.isEmpty) return fakeDrivePlayable(name: name);
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

/// A URL the server would answer with: loopback, a random key, and nothing
/// in it about the account or the file.
DriveFilePlayable fakeDrivePlayable({
  String key = '7f1c2e64-0a31-4f9b-9c2d-5b8e0a9d3c11',
  String? name,
  String contentType = 'video/x-matroska',
  int length = 4096,
}) => DriveFilePlayable(
  url: Uri.parse('http://127.0.0.1:41871/drive/stream/$key'),
  name: name,
  contentType: contentType,
  length: length,
);
