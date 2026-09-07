import 'package:xtremio/core/core.dart';

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
