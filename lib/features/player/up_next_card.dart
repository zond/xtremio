import 'package:flutter/material.dart';

import '../../shell/device_profile.dart';

/// Offered when an episode ends and the engine knows the next one: counts
/// down to playing it, with a way out.
///
/// Both buttons are focusable, so a remote can take the hand-off early or
/// call it off once the player has moved focus onto the card. They wear
/// the theme floor's stroke and nothing more: the card is an opaque
/// surface of the app's own drawn over the video, so a light stroke has a
/// known background under it, and two buttons side by side in a card that
/// is itself a hand-over prompt are not things to lift off it.
class UpNextCard extends StatelessWidget {
  const UpNextCard({
    super.key,
    required this.label,
    required this.title,
    required this.secondsLeft,
    required this.onPlay,
    required this.onDismiss,
    this.playFocusNode,
  });

  /// `S1E2`-style label; may be empty.
  final String label;
  final String title;
  final int secondsLeft;
  final VoidCallback onPlay;
  final VoidCallback onDismiss;

  /// Attached to "Play now": where the remote lands when it reaches the
  /// card, with Cancel a left press away.
  final FocusNode? playFocusNode;

  /// How wide the card is allowed to get, on a phone or a desktop and on
  /// a television.
  ///
  /// A television needs the extra hundred: the ten-foot density and the
  /// text scale together take the two buttons from 205 dp to 336, which
  /// does not fit inside 320 with the card's own padding. Getting that
  /// wrong is not a cramped layout, it is a red box drawn over the video
  /// at the one moment the viewer is being asked a question.
  static const double maxWidth = 320;
  static const double tvMaxWidth = 420;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: DeviceScope.isTv(context) ? tvMaxWidth : maxWidth,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Up next', style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(
                label.isEmpty ? title : '$label · $title',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Playing in $secondsLeft s',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              // A [Wrap] and not a [Row], and the countdown on a line of
              // its own above it. Three things across the card fit on a
              // phone and did not on a television: the countdown was an
              // [Expanded] and gave way until it was wrapping down the
              // card, and the two buttons still overflowed the row. The
              // width above is what makes them fit side by side, which is
              // how the remote walks them; the wrap is what happens
              // instead of an overflow when a viewer has also asked the
              // platform for larger text.
              //
              // The [Align] is what puts them at the end of the card,
              // which the [Row] did for nothing: a [Wrap] laid out on a
              // [Column]'s cross axis is handed loose constraints and
              // takes the width of its own children, so
              // `WrapAlignment.end` has no room to distribute and the two
              // buttons come out flush left under the "Up next" label.
              // The [Align] takes the width instead and the wrap aligns
              // inside it, on the last line too when the text is large
              // enough to break them apart.
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    TextButton(
                      onPressed: onDismiss,
                      child: const Text('Cancel'),
                    ),
                    FilledButton.icon(
                      focusNode: playFocusNode,
                      onPressed: onPlay,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play now'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
