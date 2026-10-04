import 'package:flutter/material.dart';

import '../player/seek_bar.dart';
import '../player/time_format.dart';
import 'cast_client.dart';

/// The list of receivers the cast button opens.
///
/// Rows on a sheet of the app's own, so the theme floor (`FocusTheme`)
/// fills the one the remote is on and nothing here draws a ring -- the
/// same decision the player's track menus record. The transport buttons
/// below, on [CastRemotePanel], are over the video but on its black scrim,
/// where the floor's stroke reads.
///
/// Only receivers, and only ones that were found: there is no "searching"
/// spinner to sit through, because the button that opens this is itself
/// only on screen once at least one has answered.
class CastDeviceSheet extends StatelessWidget {
  const CastDeviceSheet({
    super.key,
    required this.devices,
    required this.connected,
    required this.onSelect,
    required this.onDisconnect,
  });

  final List<CastDevice> devices;

  /// The receiver already playing this, if any.
  final CastDevice? connected;

  final ValueChanged<CastDevice> onSelect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Text('Cast to', style: textTheme.titleMedium),
          ),
          for (final device in devices)
            ListTile(
              key: ValueKey('cast-device-${device.id}'),
              leading: Icon(
                device == connected ? Icons.cast_connected : Icons.cast,
              ),
              title: Text(device.name),
              subtitle: device.model == null ? null : Text(device.model!),
              selected: device == connected,
              onTap: () => onSelect(device),
            ),
          if (connected != null)
            ListTile(
              key: const ValueKey('cast-stop'),
              leading: const Icon(Icons.stop_circle_outlined),
              title: const Text('Stop casting'),
              onTap: onDisconnect,
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// The player screen while a receiver has the stream: the same transport,
/// pointed somewhere else.
///
/// There is no video here — the pixels are on the television — so the screen
/// says what is playing, where it has got to, and what the buttons will do
/// to it. Everything it shows comes from the receiver's own status, so a
/// pause from the Chromecast's remote (or from another phone) shows up here
/// too.
class CastRemotePanel extends StatelessWidget {
  const CastRemotePanel({
    super.key,
    required this.deviceName,
    required this.title,
    required this.status,
    required this.onPlayPause,
    required this.onSeek,
    required this.onStop,
    this.note,
    this.direct = false,
    this.playPauseFocusNode,
  });

  /// What the remote says under the receiver's name while it fetches the
  /// stream from its source and nothing comes from this device.
  static const String directLine = 'Playing directly from the source';

  final String deviceName;
  final String title;
  final CastStatus status;

  /// The receiver fetches the stream from its source itself ([directLine]),
  /// not from this device: what tells a later report about a cast which of
  /// the two it was.
  final bool direct;

  /// A sentence about the session that is not the receiver's to say: the
  /// receiver reached this device and has not been sent the film yet.
  final String? note;

  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;

  /// Ends the session and brings playback back to this device.
  final VoidCallback onStop;

  final FocusNode? playPauseFocusNode;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final duration = status.duration ?? Duration.zero;
    final playing = status.state.isPlaying;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cast_connected, size: 56, color: Colors.white),
              const SizedBox(height: 16),
              Text(
                'Casting to $deviceName',
                textAlign: TextAlign.center,
                style: textTheme.titleMedium?.copyWith(color: Colors.white70),
              ),
              if (direct) ...[
                const SizedBox(height: 4),
                Text(
                  directLine,
                  key: const ValueKey('cast-direct'),
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall?.copyWith(color: Colors.white54),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleLarge?.copyWith(color: Colors.white),
              ),
              if (note case final note?) ...[
                const SizedBox(height: 12),
                Text(
                  note,
                  key: const ValueKey('cast-note'),
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(color: Colors.white70),
                ),
              ],
              const SizedBox(height: 24),
              SeekBar(
                position: status.position,
                buffered: status.position,
                duration: duration,
                onSeek: onSeek,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    formatTime(status.position),
                    style: textTheme.labelMedium?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                  Text(
                    formatTime(duration),
                    style: textTheme.labelMedium?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    key: const ValueKey('cast-rewind'),
                    tooltip: 'Back 10 seconds',
                    color: Colors.white,
                    iconSize: 32,
                    onPressed: () =>
                        onSeek(status.position - const Duration(seconds: 10)),
                    icon: const Icon(Icons.replay_10),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const ValueKey('cast-play-pause'),
                    tooltip: playing ? 'Pause' : 'Play',
                    focusNode: playPauseFocusNode,
                    iconSize: 40,
                    onPressed: onPlayPause,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    key: const ValueKey('cast-forward'),
                    tooltip: 'Forward 10 seconds',
                    color: Colors.white,
                    iconSize: 32,
                    onPressed: () =>
                        onSeek(status.position + const Duration(seconds: 10)),
                    icon: const Icon(Icons.forward_10),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                key: const ValueKey('cast-stop-button'),
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop casting'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Says why a stream cannot go to a receiver, and that the conversion which
/// would fix it does not exist yet.
///
/// A dialog rather than a snackbar: this is the answer to something the
/// viewer asked for, it is a couple of sentences long, and the alternative
/// -- letting the load fail on the television -- is what this whole check
/// exists to avoid.
class CastRefusedDialog extends StatelessWidget {
  const CastRefusedDialog({
    super.key,
    required this.explanation,
    this.title = defaultTitle,
  });

  /// What a refusal is headed when it is an answer, which is all but one.
  static const String defaultTitle = 'This stream cannot be cast';

  final String explanation;

  /// The heading. A refusal that is only a "not yet" says so here rather
  /// than under a title that has already made up its mind.
  final String title;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(title),
    content: Text(explanation),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('OK'),
      ),
    ],
  );
}

/// **The phone getting a converted stream ready before the television is
/// told about it** (a rendition, stream-server `docs/design/renditions.md`).
///
/// The receiver gives up on a load whose first answer stays silent for long
/// -- measured on a Chromecast with Google TV against a torrent whose first
/// piece and index took a minute -- so the television is handed the stream
/// only once its start is made. Until then this card is drawn over the
/// video, which keeps playing here, with what the server is doing and a
/// Cancel that leaves the film on this screen.
class CastPreparingPanel extends StatelessWidget {
  const CastPreparingPanel({
    super.key,
    required this.deviceName,
    required this.phase,
    required this.onCancel,
    this.speed,
  });

  final String deviceName;

  /// What the server is doing, as one line ([phaseLine]).
  final String phase;

  /// The torrent's download speed, already formatted, when there is one.
  final String? speed;

  final VoidCallback onCancel;

  /// What the card says the server is doing, by the readiness phase the
  /// server reports (`index` reading the film's index and formats, `start`
  /// making the part the television starts with).
  static String phaseLine(String phase) => switch (phase) {
    'start' => "Fetching the start…",
    _ => "Reading the film's index…",
  };

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 72, left: 16, right: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Preparing for $deviceName…',
                          style: textTheme.titleSmall?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          phase,
                          style: textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                        if (speed case final speed?)
                          Text(
                            speed,
                            style: textTheme.bodySmall?.copyWith(
                              color: Colors.white54,
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('cast-prepare-cancel'),
                    onPressed: onCancel,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
