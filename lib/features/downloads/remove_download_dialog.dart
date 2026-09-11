import 'package:flutter/material.dart';

import '../../core/core.dart';

/// Confirms a removal, wherever it was asked for: the Downloads list, a
/// stream tile of the release that is kept, an episode's badge. One
/// dialog, so what it says is the same everywhere.
///
/// **A removal deletes, and the dialog says so.** It used to offer to keep
/// the file "as ordinary cache", which dropped the pin and nothing else --
/// and a torrent nobody has pinned and nobody is playing is exactly what
/// the server gives back at its next pass. The bytes went a moment later
/// either way, under a message that said they had stayed. So there is one
/// thing to confirm, and the bytes going is part of it. The one case where
/// they stay -- the same file kept for another title too -- is said by the
/// message after the removal, which is the first point anything knows it.
///
/// Popping `true` confirms; anything else is a cancel.
///
/// Two buttons on a dialog's own surface, so the theme floor is the whole
/// of what marks them -- which is the point of having a floor at all: a
/// dialog is exactly the kind of surface nobody remembers to wrap, and this
/// one is the last thing a viewer sees before a file goes.
class RemoveDownloadDialog extends StatelessWidget {
  const RemoveDownloadDialog({super.key, required this.view});

  final DownloadView view;

  static const String deleteLabel = 'Delete';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Delete ${view.name}?'),
    content: Text(
      'It stops being kept for offline playback, and the '
      '${view.downloadedLabel} already downloaded is deleted from this '
      'device. Watching it again streams it.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text(deleteLabel),
      ),
    ],
  );
}

/// Puts [RemoveDownloadDialog] to the user: true when the removal, and the
/// bytes with it, was confirmed.
Future<bool> askToRemoveDownload(
  BuildContext context,
  DownloadView view,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => RemoveDownloadDialog(view: view),
    ) ??
    false;
