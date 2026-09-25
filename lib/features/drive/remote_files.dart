import 'package:flutter/material.dart';

import '../../shell/device_profile.dart';
import 'drive_pairing_screen.dart';

/// Where files this device does not hold are linked from: the button in the
/// library's app bar, and the short list of services it opens.
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
/// It is drawn as an icon button in the **library's** app bar. The board is
/// what an addon catalogue offers and the library is what the viewer has;
/// a file on their own Drive is theirs, not a catalogue's, so this is a
/// control about the library. It sat on the board first and that was the
/// wrong shelf. Discreet either way: linking a remote file is something a
/// viewer does once a month.
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
/// pairing lands on the library rather than on the list it was chosen from
/// -- a viewer who abandons a pairing wants their titles, not the menu
/// again.
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

/// The short list of services, drawn so that a row of it is plainly a thing
/// to press.
///
/// **It read as a message with a Cancel button.** One [ListTile] on a
/// dialog's surface has no edge, no fill and no arrow: the only control on
/// screen with a button's shape was the one that closed it, so a viewer who
/// had never seen this before was being asked to guess that the sentence was
/// tappable. That is a dialog that says "no" for you.
///
/// So the row is an [OutlinedButton]: an outline that is there before the
/// remote arrives rather than only under it, an arrow saying it leads
/// somewhere, and -- the half that matters on a television -- a button's own
/// semantics, so the readout says *button* and not a line of prose.
///
/// On a television the row also takes focus on arrival, the way an actions
/// sheet's first action does. A remote has nothing to point with, and a
/// dialog whose focus starts on Cancel is one press from doing nothing.
class _RemoteFilesDialog extends StatelessWidget {
  const _RemoteFilesDialog();

  static const String title = 'Link files';
  static const String driveLabel = 'Google Drive';
  static const String driveSubtitle =
      'Pick a file on your phone; this '
      'device reads it.';
  static const String cancelLabel = 'Cancel';

  /// What a test finds the Drive row by, rather than by being the first
  /// button on a dialog whose other button is Cancel.
  static const Key driveKey = Key('remote-service-google-drive');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTv = DeviceScope.isTv(context);
    return AlertDialog(
      title: const Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The floor reaches this on top of the outline it already wears:
          // an [OutlinedButton] is Material's own ink on the dialog's own
          // surface, so [FocusTheme] marks it with the fill and there is no
          // poster art under it for a near-white wash to disappear into
          // (`AGENTS.md`, "Prefer the floor"). `focus_reach_test.dart` walks
          // this row and would fail on a stop with nothing drawn on it.
          OutlinedButton(
            key: driveKey,
            autofocus: isTv,
            onPressed: () =>
                Navigator.of(context).pop(_RemoteService.googleDrive),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              alignment: AlignmentDirectional.centerStart,
            ),
            child: Row(
              children: [
                const Icon(Icons.cloud_outlined),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // First, so `focusedLabel` reads the service and not
                      // the sentence under it.
                      Text(driveLabel, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        driveSubtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right),
              ],
            ),
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
}
