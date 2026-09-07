import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/sharing/sharing_activity.dart';

/// A [ServerSettingsWriter] that records what the app asked the embedded
/// server to change, instead of reaching FFI.
class RecordingServerSettings implements ServerSettingsWriter {
  RecordingServerSettings({this.failWhile = 0});

  /// Every patch, in order and exactly as it was written -- the keys are
  /// the server's own spellings and a test reads them literally.
  final List<Map<String, dynamic>> patches = [];

  /// How many of the first calls throw, for the "the server is not up yet"
  /// path.
  int failWhile;

  @override
  Future<Map<String, dynamic>> updateSettings(
    Map<String, dynamic> patch,
  ) async {
    if (failWhile > 0) {
      failWhile -= 1;
      throw StateError('server is not running');
    }
    patches.add(patch);
    return patch;
  }
}

/// A [SharingActivityClient] a test answers for, instead of asking a server
/// nothing can ask yet (see [SharingActivityClient] for why there is no real
/// one).
class FakeSharingActivity implements SharingActivityClient {
  /// The rate and the torrent count every reading reports, and the counter
  /// it starts from.
  SharingActivity answer = SharingActivity.none;

  /// Bytes added to the counter on every reading. A share that is really
  /// going on moves it, and that is what the monitor measures; an answer
  /// frozen at one number is a share that has stopped, however high the
  /// number is. So a test that means "still uploading" sets this.
  int perRead = 0;

  /// Thrown by [fetch] while it is set, for the server-is-not-up path.
  Object? failure;

  /// How many readings have been taken, so a test can see the polling stop.
  int reads = 0;

  int _grown = 0;

  @override
  Future<SharingActivity> fetch() async {
    reads += 1;
    final failure = this.failure;
    if (failure != null) throw failure;
    _grown += perRead;
    return SharingActivity(
      uploadSpeed: answer.uploadSpeed,
      uploadedBytes: answer.uploadedBytes + _grown,
      torrents: answer.torrents,
    );
  }
}
