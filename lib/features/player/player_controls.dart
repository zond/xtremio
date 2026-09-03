import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../shell/device_profile.dart';
import 'seek_bar.dart';
import 'time_format.dart';

const _gradientBlack = Color(0xCC000000);

/// The bar over the top edge of the video: back, title, and the menus.
///
/// Every button here is focusable, so a remote reaches the menus once the
/// player has moved focus onto the bar ([firstFocusNode] is where it lands:
/// the leftmost control, with the rest a right press away). They are keyed
/// so that a button that stops being built (the episode was the last one,
/// the second audio track went away) takes its own element and focus node
/// with it, rather than passing them to its neighbour and leaving the
/// remote pointed at a button the viewer never chose.
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
    this.firstFocusNode,
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

  /// Attached to the back button: what the player focuses when the remote
  /// moves focus up onto this bar.
  final FocusNode? firstFocusNode;

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
            IconButton(
              // A [BackButton] in all but name; that one takes no focus
              // node, and the remote has to be able to land on this one.
              key: const ValueKey('back'),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              color: Colors.white,
              focusNode: firstFocusNode,
              onPressed: () => Navigator.maybePop(context),
              icon: const BackButtonIcon(),
            ),
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
                key: const ValueKey('next'),
                tooltip: 'Next episode (N)',
                color: Colors.white,
                onPressed: onNext,
                icon: const Icon(Icons.skip_next),
              ),
            if (onSubtitles != null)
              IconButton(
                key: const ValueKey('subtitles'),
                tooltip: 'Subtitles (S)',
                color: Colors.white,
                onPressed: onSubtitles,
                icon: Icon(subtitlesOn ? Icons.subtitles : Icons.subtitles_off),
              ),
            if (onAudio != null)
              IconButton(
                key: const ValueKey('audio'),
                tooltip: 'Audio track (A)',
                color: Colors.white,
                onPressed: onAudio,
                icon: const Icon(Icons.audiotrack),
              ),
            IconButton(
              key: const ValueKey('stats'),
              tooltip: 'Playback stats (Shift+I)',
              color: Colors.white,
              isSelected: statsOn,
              onPressed: onStats,
              icon: const Icon(Icons.query_stats),
            ),
            IconButton(
              key: const ValueKey('settings'),
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

/// Seconds label and icon for a seek step: mpv-style `replay_10` glyphs
/// where Material has one for the step, generic rewind/forward otherwise.
String seekLabel(Duration step) => '${step.inSeconds} seconds';

IconData seekBackIcon(Duration step) => switch (step.inSeconds) {
  5 => Icons.replay_5,
  10 => Icons.replay_10,
  30 => Icons.replay_30,
  _ => Icons.fast_rewind,
};

IconData seekForwardIcon(Duration step) => switch (step.inSeconds) {
  5 => Icons.forward_5,
  10 => Icons.forward_10,
  30 => Icons.forward_30,
  _ => Icons.fast_forward,
};

/// The large play/pause and ±[seekStep] buttons in the middle of the video
/// (phone layout; on wide screens they live in [PlayerBottomBar]).
class PlayerCenterControls extends StatelessWidget {
  const PlayerCenterControls({
    super.key,
    required this.playing,
    required this.seekStep,
    required this.onPlayPause,
    required this.onSeekBack,
    required this.onSeekForward,
  });

  final bool playing;

  /// What the seek buttons move by (`seekTimeDuration`), for their labels.
  final Duration seekStep;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Back ${seekLabel(seekStep)}',
          iconSize: 40,
          color: Colors.white,
          onPressed: onSeekBack,
          icon: Icon(seekBackIcon(seekStep)),
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
          tooltip: 'Forward ${seekLabel(seekStep)}',
          iconSize: 40,
          color: Colors.white,
          onPressed: onSeekForward,
          icon: Icon(seekForwardIcon(seekStep)),
        ),
      ],
    );
  }
}

/// The bar over the bottom edge: seek bar, transport, time, volume and
/// fullscreen. [wide] puts the transport here; otherwise
/// [PlayerCenterControls] carries it.
///
/// On a television the seek bar joins the buttons as a focus stop (left and
/// right seek while it holds focus), so the whole bar is reachable with the
/// D-pad, and the two controls a remote cannot work are left out: the
/// volume slider (a drag; the set has its own volume keys) and the
/// fullscreen button (the player is fullscreen the whole time it is up).
class PlayerBottomBar extends StatelessWidget {
  const PlayerBottomBar({
    super.key,
    required this.wide,
    required this.playing,
    required this.seekStep,
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
    this.playPauseFocusNode,
    this.seekBarFocusNode,
  });

  final bool wide;
  final bool playing;

  /// What the seek buttons move by (`seekTimeDuration`), for their labels.
  final Duration seekStep;
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

  /// Attached to the play/pause button of the [wide] transport: what the
  /// player focuses when the remote moves focus down onto this bar.
  final FocusNode? playPauseFocusNode;

  /// Attached to the seek bar where it is a focus stop: what the player
  /// asks whether the remote is on the bar rather than on a button.
  final FocusNode? seekBarFocusNode;

  @override
  Widget build(BuildContext context) {
    final isTv = DeviceScope.isTv(context);
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
          focusable: isTv,
          focusNode: seekBarFocusNode,
          seekStep: seekStep,
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
                    focusNode: playPauseFocusNode,
                    iconSize: 32,
                    onPressed: onPlayPause,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  ),
                  IconButton(
                    tooltip: 'Back ${seekLabel(seekStep)} (←)',
                    color: Colors.white,
                    onPressed: onSeekBack,
                    icon: Icon(seekBackIcon(seekStep)),
                  ),
                  IconButton(
                    tooltip: 'Forward ${seekLabel(seekStep)} (→)',
                    color: Colors.white,
                    onPressed: onSeekForward,
                    icon: Icon(seekForwardIcon(seekStep)),
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
                  // Only where something can drag it: a [Slider] takes
                  // every arrow key for itself, so a remote that landed on
                  // it could never leave again, and the set has its own
                  // volume keys anyway. Mute stays, as a key does that.
                  if (!isTv)
                    SizedBox(
                      width: 120,
                      child: Slider(
                        value: volume.clamp(0, 100),
                        max: 100,
                        onChanged: onVolume,
                      ),
                    ),
                ],
                if (!isTv) fullscreenButton,
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
