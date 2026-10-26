import 'torrent_stall_overlay.dart';

/// What the player says in the middle of the screen while there is no film
/// to watch: a failure, or what it is waiting for.
///
/// [of] decides, in the order a viewer needs to hear it. A failure comes
/// before everything, and buffering only once a stream is open. A status is
/// either a wait (a spinner beside the words) or an end ([failed], an icon
/// instead).
sealed class PlayerStatus {
  const PlayerStatus();

  /// The status for these facts, or null when the film is playing and there
  /// is nothing to say.
  ///
  /// [engineError] is the engine's failure to open the stream. [loaded] is
  /// the core having a stream at all, and [unplayable] its reason that the
  /// stream cannot play. [opened] is the engine having been handed it.
  /// [waiting] covers every way playback stands still, and [torrent] says
  /// whose words it gets.
  static PlayerStatus? of({
    required String? engineError,
    required bool loaded,
    required String? unplayable,
    required bool opened,
    required bool waiting,
    required bool torrent,
  }) {
    if (engineError != null) return PlaybackFailed(engineError);
    if (!loaded) return const PlayerLoading();
    if (unplayable != null) return StreamUnplayable(unplayable);
    if (!opened) return const StreamOpening();
    if (waiting) return PlayerWaiting(torrent: torrent);
    return null;
  }

  /// The sentence on screen.
  String get text;

  /// Whether this is the end of trying: an icon instead of the spinner.
  bool get failed => false;
}

/// The engine could not open the stream.
final class PlaybackFailed extends PlayerStatus {
  const PlaybackFailed(this.error);

  /// What the engine said.
  final String error;

  @override
  String get text => 'Playback failed: $error';

  @override
  bool get failed => true;
}

/// The core has no stream loaded yet.
final class PlayerLoading extends PlayerStatus {
  const PlayerLoading();

  @override
  String get text => 'Loading…';
}

/// The core loaded a stream that cannot be played.
final class StreamUnplayable extends PlayerStatus {
  const StreamUnplayable(this.reason);

  /// Why, in the core's words.
  final String reason;

  @override
  String get text => reason;

  @override
  bool get failed => true;
}

/// The stream is being resolved and has not reached the engine.
final class StreamOpening extends PlayerStatus {
  const StreamOpening();

  @override
  String get text => 'Opening the stream…';
}

/// Playback has begun and is standing still.
final class PlayerWaiting extends PlayerStatus {
  const PlayerWaiting({required this.torrent});

  /// A torrent says what the stall card says when the server has nothing to
  /// tell yet.
  final bool torrent;

  @override
  String get text => torrent ? TorrentStallOverlay.waiting : 'Buffering…';
}
