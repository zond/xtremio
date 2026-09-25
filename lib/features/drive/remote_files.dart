import 'package:flutter/material.dart';

import 'drive_pairing_screen.dart';

/// Where files this device does not hold are linked from: the button on the
/// board, and the short list of services it opens.
///
/// **The button does not say Google Drive**, and the dialog is not a
/// shortcut past it. Drive is the only entry today and the dialog is
/// therefore one row -- which looks like a dialog that could be skipped
/// until you read what is coming: `docs/translated-sources.md` in the
/// streaming server names `SmbSource` and `NfsSource` as the same seam as
/// `DriveSource`, "a `ProxySource` with a header supplier that refreshes",
/// and being the same seam is the point of having one. A share on the
/// landing and a folder on a NAS arrive as rows here. A button wired
/// straight to the Drive pairing would have to be renamed, re-drawn and
/// re-taught to the remote on the day the second one lands, and the viewer
/// would have learnt a button that meant one thing and now means another.
///
/// It is drawn as an icon button in the board's app bar, which is where
/// this app puts the controls that are about the board rather than about
/// anything on it. Discreet on purpose: linking a remote file is something
/// a viewer does once a month, and the board is the wall of posters they
/// came for.
class RemoteFilesButton extends StatelessWidget {
  const RemoteFilesButton({super.key});

  /// What the remote reads out and what a test finds it by. Not "Google
  /// Drive": see the class comment.
  static const String label = 'Link files on remote services';

  @override
  Widget build(BuildContext context) => IconButton(
    // The floor and nothing put on by hand: an app bar's icon button is
    // Material's own ink on Material's own surface, so [FocusTheme] reaches
    // it with a stroke and a fill (`AGENTS.md`, "Prefer the floor"). There
    // is no poster art under this one for a wash to disappear into.
    icon: const Icon(Icons.cloud_outlined),
    tooltip: label,
    onPressed: () => showRemoteFilesDialog(context),
  );
}

/// Opens the short list of services, and then whatever the viewer picked.
///
/// The dialog closes *before* the pairing screen is pushed, so Back from a
/// pairing lands on the board rather than on the list it was chosen from --
/// a viewer who abandons a pairing wants the posters, not the menu again.
Future<void> showRemoteFilesDialog(BuildContext context) async {
  final navigator = Navigator.of(context);
  final picked = await showDialog<_RemoteService>(
    context: context,
    builder: (context) => const _RemoteFilesDialog(),
  );
  if (picked == null) return;
  switch (picked) {
    case _RemoteService.googleDrive:
      await navigator.push(
        MaterialPageRoute<void>(builder: (_) => const DrivePairingScreen()),
      );
  }
}

/// The services a file can be linked from. One today; the enum is what
/// makes adding the second one a row and a case rather than a rewrite.
enum _RemoteService { googleDrive }

class _RemoteFilesDialog extends StatelessWidget {
  const _RemoteFilesDialog();

  static const String title = 'Link files';
  static const String driveLabel = 'Google Drive';
  static const String driveSubtitle =
      'Pick a file on your phone; this '
      'device reads it.';
  static const String cancelLabel = 'Cancel';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text(title),
    // No padding of its own: the rows are [ListTile]s and bring theirs.
    contentPadding: const EdgeInsets.symmetric(vertical: 12),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The floor and nothing put on by hand. A [ListTile] on a dialog's
        // own surface is Material's ink, so [FocusTheme] marks it with the
        // fill -- which is the whole indicator a tile can carry, since it
        // cannot be given a side -- and there is no poster art under it for
        // a near-white wash to disappear into (`AGENTS.md`, "Prefer the
        // floor"). `focus_reach_test.dart` walks this row and would fail on
        // a stop with nothing drawn on it.
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: const Text(driveLabel),
          subtitle: const Text(driveSubtitle),
          onTap: () => Navigator.of(context).pop(_RemoteService.googleDrive),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text(cancelLabel),
      ),
    ],
  );
}
