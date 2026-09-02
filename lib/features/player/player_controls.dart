import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'seek_bar.dart';
import 'time_format.dart';

const _gradientBlack = Color(0xCC000000);

/// The bar over the top edge of the video: back, title, and the menus.
class PlayerTopBar extends StatelessWidget {
  const PlayerTopBar({
    super.key,
    required this.title,
    required this.subtitlesOn,
    required this.onSubtitles,
    required this.onAudio,
    required this.statsOn,
    required this.onStats,
    required this.onSettings,
    required this.onNext,
  });

  final String title;
  final bool subtitlesOn;

  /// Null hides the button (no subtitle support wired up).
  final VoidCallback? onSubtitles;

  /// Null hides the button (one or no audio tracks).
  final VoidCallback? onAudio;
  final bool statsOn;
  final VoidCallback onStats;
  final VoidCallback onSettings;

  /// Null hides the button (no next episode).
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_gradientBlack, Color(0x00000000)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 16),
        child: Row(
          children: [
            const BackButton(color: Colors.white),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleMedium?.copyWith(color: Colors.white),
              ),
            ),
            if (onNext != null)
              IconButton(
                tooltip: 'Next episode (N)',
                color: Colors.white,
                onPressed: onNext,
                icon: const Icon(Icons.skip_next),
              ),
            if (onSubtitles != null)
              IconButton(
                tooltip: 'Subtitles (S)',
                color: Colors.white,
                onPressed: onSubtitles,
                icon: Icon(subtitlesOn ? Icons.subtitles : Icons.subtitles_off),
              ),
            if (onAudio != null)
              IconButton(
                tooltip: 'Audio track (A)',
                color: Colors.white,
                onPressed: onAudio,
                icon: const Icon(Icons.audiotrack),
              ),
            IconButton(
              tooltip: 'Playback stats (Shift+I)',
              color: Colors.white,
              isSelected: statsOn,
              onPressed: onStats,
              icon: const Icon(Icons.query_stats),
            ),
            IconButton(
              tooltip: 'Playback settings',
              color: Colors.white,
              onPressed: onSettings,
              icon: const Icon(Icons.settings),
            ),
          ],
        ),
      ),
    );
  }
}

/// The large play/pause and ±10 s buttons in the middle of the video
/// (phone layout; on wide screens they live in [PlayerBottomBar]).
class PlayerCenterControls extends StatelessWidget {
  const PlayerCenterControls({
    super.key,
    required this.playing,
    required this.onPlayPause,
    required this.onSeekBack,
    required this.onSeekForward,
  });

  final bool playing;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Back 10 seconds',
          iconSize: 40,
          color: Colors.white,
          onPressed: onSeekBack,
          icon: const Icon(Icons.replay_10),
        ),
        const SizedBox(width: 24),
        IconButton.filled(
          tooltip: playing ? 'Pause' : 'Play',
          iconSize: 48,
          onPressed: onPlayPause,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
        ),
        const SizedBox(width: 24),
        IconButton(
          tooltip: 'Forward 10 seconds',
          iconSize: 40,
          color: Colors.white,
          onPressed: onSeekForward,
          icon: const Icon(Icons.forward_10),
        ),
      ],
    );
  }
}

/// The bar over the bottom edge: seek bar, transport, time, volume and
/// fullscreen. [wide] puts the transport here; otherwise
/// [PlayerCenterControls] carries it.
class PlayerBottomBar extends StatelessWidget {
  const PlayerBottomBar({
    super.key,
    required this.wide,
    required this.playing,
    required this.position,
    required this.buffered,
    required this.duration,
    required this.showRemaining,
    required this.volume,
    required this.fullscreen,
    required this.onPlayPause,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onSeek,
    required this.onScrubStart,
    required this.onScrubEnd,
    required this.onToggleTimeDisplay,
    required this.onVolume,
    required this.onMute,
    required this.onFullscreen,
  });

  final bool wide;
  final bool playing;
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> buffered;
  final Duration duration;
  final bool showRemaining;

  /// `0..100`.
  final double volume;
  final bool fullscreen;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onScrubStart;
  final VoidCallback onScrubEnd;
  final VoidCallback onToggleTimeDisplay;
  final ValueChanged<double> onVolume;
  final VoidCallback onMute;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context) {
    final seekBar = ValueListenableBuilder<Duration>(
      valueListenable: position,
      builder: (context, position, _) => ValueListenableBuilder<Duration>(
        valueListenable: buffered,
        builder: (context, buffered, _) => SeekBar(
          position: position,
          buffered: buffered,
          duration: duration,
          onSeek: onSeek,
          onScrubStart: onScrubStart,
          onScrubEnd: onScrubEnd,
        ),
      ),
    );
    final time = _TimeText(
      position: position,
      duration: duration,
      showRemaining: showRemaining,
      onTap: onToggleTimeDisplay,
    );
    final fullscreenButton = IconButton(
      tooltip: fullscreen ? 'Exit fullscreen (F)' : 'Fullscreen (F)',
      color: Colors.white,
      onPressed: onFullscreen,
      icon: Icon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [_gradientBlack, Color(0x00000000)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            seekBar,
            Row(
              children: [
                if (wide) ...[
                  IconButton(
                    tooltip: playing ? 'Pause (Space)' : 'Play (Space)',
                    color: Colors.white,
                    iconSize: 32,
                    onPressed: onPlayPause,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  ),
                  IconButton(
                    tooltip: 'Back 10 seconds (←)',
                    color: Colors.white,
                    onPressed: onSeekBack,
                    icon: const Icon(Icons.replay_10),
                  ),
                  IconButton(
                    tooltip: 'Forward 10 seconds (→)',
                    color: Colors.white,
                    onPressed: onSeekForward,
                    icon: const Icon(Icons.forward_10),
                  ),
                  const SizedBox(width: 8),
                ],
                time,
                const Spacer(),
                if (wide) ...[
                  IconButton(
                    tooltip: volume == 0 ? 'Unmute (M)' : 'Mute (M)',
                    color: Colors.white,
                    onPressed: onMute,
                    icon: Icon(
                      volume == 0
                          ? Icons.volume_off
                          : volume < 50
                          ? Icons.volume_down
                          : Icons.volume_up,
                    ),
                  ),
                  SizedBox(
                    width: 120,
                    child: Slider(
                      value: volume.clamp(0, 100),
                      max: 100,
                      onChanged: onVolume,
                    ),
                  ),
                ],
                fullscreenButton,
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// `elapsed / total`, or `-remaining / total` after a tap.
class _TimeText extends StatelessWidget {
  const _TimeText({
    required this.position,
    required this.duration,
    required this.showRemaining,
    required this.onTap,
  });

  final ValueListenable<Duration> position;
  final Duration duration;
  final bool showRemaining;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Colors.white,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: ValueListenableBuilder<Duration>(
          valueListenable: position,
          builder: (context, position, _) {
            final elapsed = showRemaining
                ? formatTime(position - duration)
                : formatTime(position);
            return Text('$elapsed / ${formatTime(duration)}', style: style);
          },
        ),
      ),
    );
  }
}
