import 'package:flutter/material.dart';

/// Offered when an episode ends and the engine knows the next one: counts
/// down to playing it, with a way out.
///
/// Both buttons are focusable, so a remote can take the hand-off early or
/// call it off once the player has moved focus onto the card.
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
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
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Playing in $secondsLeft s',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(onPressed: onDismiss, child: const Text('Cancel')),
                  FilledButton.icon(
                    focusNode: playFocusNode,
                    onPressed: onPlay,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play now'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
