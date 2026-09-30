import 'package:xtremio/core/server_client.dart';

/// A [PlaybackHints] that records instead of telling the server.
class FakePlaybackHints implements PlaybackHints {
  /// When set, `noteDuration` also appends `'duration'` here: the log
  /// shared with the other fakes.
  List<String>? callLog;

  /// Every duration-only report, in order, by URL or by media id.
  final List<double> durations = [];

  /// Which file each report by URL named, as the player URL spelled it: the
  /// segment (`-1` for a file the server picks) and the `f=` filters.
  final List<({int fileIdx, List<String> filters})> files = [];

  /// Every torrent a player was reported opened on, in order.
  final List<String> opened = [];

  /// Every stall reported, as the torrent it was reported for, in order.
  final List<String> stalls = [];

  @override
  Future<void> noteDuration({
    required String infoHash,
    required int fileIdx,
    required List<String> filters,
    required double durationSeconds,
  }) async {
    callLog?.add('duration');
    durations.add(durationSeconds);
    files.add((fileIdx: fileIdx, filters: filters));
  }

  @override
  Future<void> notePlayerOpened({required String infoHash}) async {
    callLog?.add('opened');
    opened.add(infoHash);
  }

  @override
  Future<void> notePlayerStalled({required String infoHash}) async {
    callLog?.add('stalled');
    stalls.add(infoHash);
  }

  /// Every duration reported by media id, as `(id, seconds)`. The seconds
  /// also go to [durations], which is every length reported either way.
  final List<(String, double)> mediaDurations = [];

  /// Every media id a player was reported opened on, in order.
  final List<String> mediaOpened = [];

  /// Every stall reported by media id, in order.
  final List<String> mediaStalls = [];

  @override
  Future<void> noteMediaDuration({
    required String id,
    required double durationSeconds,
  }) async {
    callLog?.add('duration');
    durations.add(durationSeconds);
    mediaDurations.add((id, durationSeconds));
  }

  @override
  Future<void> noteMediaPlayerOpened({required String id}) async {
    callLog?.add('opened');
    mediaOpened.add(id);
  }

  @override
  Future<void> noteMediaPlayerStalled({required String id}) async {
    callLog?.add('stalled');
    mediaStalls.add(id);
  }
}
