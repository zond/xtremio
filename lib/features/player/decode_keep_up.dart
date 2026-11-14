import 'playback_stats.dart';

/// What [DecodeKeepUp.tick] asks the engine to do.
enum KeepUpStep {
  /// Nothing yet.
  wait,

  /// Read the drop counters now, as the start of the measured stretch.
  baseline,

  /// Read the numbers again and judge them ([decodingFallsBehind]).
  sample,
}

/// When to check, once per film, that software decoding keeps up.
///
/// A film the surface cannot show is decoded in software on the texture. A
/// weak device can play the sound and show a picture that falls behind it.
/// The engine ticks this every [interval] while it watches. Only a tick
/// while the film plays and is not buffering counts. The first one that
/// counts asks for a [KeepUpStep.baseline]. The one [measured] later asks
/// for the [KeepUpStep.sample], and nothing is asked after that.
class DecodeKeepUp {
  /// How often the engine ticks.
  static const Duration interval = Duration(seconds: 1);

  /// How much playback lies between the baseline and the sample.
  static const Duration measured = Duration(seconds: 8);

  bool _started = false;
  bool _done = false;
  int _counted = 0;

  /// Whether the check has run for this film.
  bool get done => _done;

  /// Playback counted since the baseline.
  Duration get played => interval * _counted;

  /// One tick, with whether the film is [playing] and [buffering].
  KeepUpStep tick({required bool playing, required bool buffering}) {
    if (_done || !playing || buffering) return KeepUpStep.wait;
    if (!_started) {
      _started = true;
      return KeepUpStep.baseline;
    }
    _counted++;
    if (played < measured) return KeepUpStep.wait;
    _done = true;
    return KeepUpStep.sample;
  }
}

/// Below this share of the film's frame rate, decoding is behind.
const double keepUpRateFloor = 0.8;

/// Above this share of the film's frames dropped, decoding is behind.
const double keepUpDropCeiling = 0.2;

/// Whether the decoder is clearly behind the film, from two readings of
/// mpv's numbers [played] apart.
///
/// It is behind when mpv's estimate of the frames it shows
/// (`estimated-vf-fps`) is under [keepUpRateFloor] of the film's own rate
/// (`container-fps`). It is also behind when more than [keepUpDropCeiling]
/// of the frames were dropped between [baseline] and [sample]
/// (`frame-drop-count` plus `decoder-frame-drop-count`). A film with no
/// declared rate decides nothing.
bool decodingFallsBehind({
  required PlaybackStats baseline,
  required PlaybackStats sample,
  required Duration played,
}) {
  final fps = sample.containerFps;
  if (fps == null || fps <= 0) return false;
  final shown = sample.outputFps;
  if (shown != null && shown < keepUpRateFloor * fps) return true;
  int dropped(PlaybackStats s) =>
      (s.droppedFrames ?? 0) + (s.decoderDroppedFrames ?? 0);
  final drops = dropped(sample) - dropped(baseline);
  final frames = fps * played.inMilliseconds / 1000;
  return frames > 0 && drops > keepUpDropCeiling * frames;
}
