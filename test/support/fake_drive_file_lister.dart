import 'dart:async';

import 'package:xtremio/core/core.dart';

/// A [DriveFileLister] a test drives by hand, and the record of what was
/// handed down to it.
///
/// **Its point is the record**, the way `FakeDriveFileOpener`'s is: what
/// matters about a listing is not only what comes back but that the grant
/// went into it and nowhere else, so [asked] keeps every refresh token it
/// was called with. Nothing here reaches the pairing service or Google.
class FakeDriveFileLister implements DriveFileLister {
  FakeDriveFileLister({List<DriveListing>? answers}) : answers = [...?answers];

  /// What each call answers, in order; the **last** one repeats forever, so
  /// a test can say "this is what a listing does" without counting presses.
  ///
  /// Empty answers a failure and not an empty listing, deliberately: an
  /// empty listing removes every stored row, and that is not what a test
  /// that never said what Drive holds meant to ask for.
  final List<DriveListing> answers;

  /// Every token this was asked with, in order.
  final List<String> asked = [];

  /// Held open, no call finishes until it is completed -- which is how a
  /// test presses a button twice while the first press is still in flight.
  Completer<void>? gate;

  /// A complete listing naming [namesById] and measuring nothing -- what
  /// the real one answers after the page that carries no `nextPageToken`,
  /// for files Drive has not processed.
  static DriveListing listing(Map<String, String> namesById) =>
      DriveFilesListed({
        for (final named in namesById.entries)
          named.key: (name: named.value, height: null, durationMillis: null),
      });

  /// A complete listing of files Drive has measured.
  static DriveListing measured(Map<String, DriveFileFacts> filesById) =>
      DriveFilesListed(filesById);

  @override
  Future<DriveListing> listFiles({required String refreshToken}) async {
    asked.add(refreshToken);
    await gate?.future;
    if (answers.isEmpty) {
      return const DriveListingFailed(DriveListingFailure.unreachable);
    }
    return answers.length == 1 ? answers.first : answers.removeAt(0);
  }
}
