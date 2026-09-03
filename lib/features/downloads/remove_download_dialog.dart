import 'package:flutter/material.dart';

import '../../core/core.dart';

/// Asks what a removal should do with the bytes, wherever the removal was
/// asked for: the Downloads list, a stream tile of the release that is
/// kept, an episode's badge. One dialog, so the question -- and the answer
/// the two buttons stand for -- is the same everywhere.
///
/// Popping `true` deletes the file, `false` keeps it as ordinary cache,
/// nothing at all cancels.
class RemoveDownloadDialog extends StatelessWidget {
  const RemoveDownloadDialog({super.key, required this.view});

  final DownloadView view;

  static const String keepLabel = 'Keep the file';
  static const String deleteLabel = 'Delete the file';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Remove ${view.name}?'),
    content: Text(
      'It stops being kept for offline playback. The '
      '${view.downloadedLabel} already downloaded can go with it, or stay '
      'as ordinary cache.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text(keepLabel),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text(deleteLabel),
      ),
    ],
  );
}

/// Puts [RemoveDownloadDialog] to the user: true takes the file with the
/// entry, false leaves it, null is a cancel and not a keep.
Future<bool?> askToRemoveDownload(BuildContext context, DownloadView view) =>
    showDialog<bool>(
      context: context,
      builder: (_) => RemoveDownloadDialog(view: view),
    );
