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

/// A reading the server would give with bytes moving [up], [down], both or
/// neither, nothing playing. The sums are whatever makes the verdict
/// plausible; nothing in the app reads them.
BackgroundTraffic traffic({bool up = false, bool down = false}) =>
    BackgroundTraffic(
      active: up || down,
      downloading: down,
      uploading: up,
      playing: false,
      bytesDownloaded: down ? 3200000 : 0,
      bytesUploaded: up ? 640000 : 0,
      windowSecs: 5,
    );

/// A [SharingActivityClient] a test answers for, instead of asking a
/// server.
class FakeSharingActivity implements SharingActivityClient {
  FakeSharingActivity({this.answer = BackgroundTraffic.none});

  /// What every reading reports until a test changes it: the monitor
  /// repeats the server's verdict, so this is the whole of the light's
  /// state.
  BackgroundTraffic answer;

  /// Thrown by [fetch] while it is set, for the server-is-not-up path.
  Object? failure;

  /// How many readings have been taken, so a test can see the polling stop.
  int reads = 0;

  @override
  Future<BackgroundTraffic> fetch() async {
    reads += 1;
    final failure = this.failure;
    if (failure != null) throw failure;
    return answer;
  }
}
