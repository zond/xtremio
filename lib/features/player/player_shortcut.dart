import 'package:flutter/services.dart';

/// The player's keyboard and media-key shortcuts: what each key means once
/// the remote's own handling (the centre key, up and down on a television,
/// the timing panel and a focused control) has passed on it.
///
/// Mostly mpv's and stremio-web's keys, plus the media keys of a remote or a
/// keyboard. Ctrl, Alt and Meta are left to the system before this is asked.
enum PlayerShortcut {
  togglePlay,
  play,
  pause,

  /// Leaves the player. A stop has no ladder to come down first.
  stop,

  /// The seek step back, longer the longer the key is held.
  seekBack,

  /// The seek step forward, longer the longer the key is held.
  seekForward,

  /// The short step back, an exact seek (Shift+Left).
  shortSeekBack,

  /// The short step forward, an exact seek (Shift+Right).
  shortSeekForward,

  volumeUp,
  volumeDown,
  mute,
  fullscreen,

  /// Leaves fullscreen or the player, as the setting says.
  escape,

  /// The list of subtitles (S).
  subtitles,

  /// What to do about the subtitle that is playing (Shift+S).
  subtitleTiming,

  audio,
  next,

  /// Starts the film over. The player knows no previous episode, so the
  /// previous-track key does what music players do.
  restart,

  /// The stats panel (Shift+I), as in mpv.
  stats;

  /// The shortcut [key] means, or null for a key the player leaves alone.
  static PlayerShortcut? of(LogicalKeyboardKey key, {required bool shift}) {
    if (shift) {
      if (key == LogicalKeyboardKey.arrowLeft) return shortSeekBack;
      if (key == LogicalKeyboardKey.arrowRight) return shortSeekForward;
      if (key == LogicalKeyboardKey.keyS) return subtitleTiming;
      if (key == LogicalKeyboardKey.keyI) return stats;
    }
    return _plain[key];
  }

  static final Map<LogicalKeyboardKey, PlayerShortcut> _plain = {
    LogicalKeyboardKey.space: togglePlay,
    LogicalKeyboardKey.keyK: togglePlay,
    LogicalKeyboardKey.mediaPlayPause: togglePlay,
    LogicalKeyboardKey.mediaPlay: play,
    LogicalKeyboardKey.mediaPause: pause,
    LogicalKeyboardKey.mediaStop: stop,
    LogicalKeyboardKey.arrowLeft: seekBack,
    LogicalKeyboardKey.keyJ: seekBack,
    LogicalKeyboardKey.mediaRewind: seekBack,
    LogicalKeyboardKey.arrowRight: seekForward,
    LogicalKeyboardKey.keyL: seekForward,
    LogicalKeyboardKey.mediaFastForward: seekForward,
    LogicalKeyboardKey.arrowUp: volumeUp,
    LogicalKeyboardKey.arrowDown: volumeDown,
    LogicalKeyboardKey.keyM: mute,
    LogicalKeyboardKey.keyF: fullscreen,
    LogicalKeyboardKey.escape: escape,
    LogicalKeyboardKey.keyS: subtitles,
    LogicalKeyboardKey.keyA: audio,
    LogicalKeyboardKey.keyN: next,
    LogicalKeyboardKey.mediaTrackNext: next,
    LogicalKeyboardKey.mediaTrackPrevious: restart,
  };

  /// Whether a held key's repeats act too. Seeking and the volume keep
  /// going while the key is down; everything else acts once, on the press.
  bool get repeats => switch (this) {
    seekBack ||
    seekForward ||
    shortSeekBack ||
    shortSeekForward ||
    volumeUp ||
    volumeDown => true,
    _ => false,
  };
}
