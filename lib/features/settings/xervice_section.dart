import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/external_link.dart';

/// What xtremio-xervice keeps for the signed-in account, and the ways to
/// take it back: under Account in Settings, signed in only, and only in a
/// build that reaches the service at all ([XerviceScope]).
///
/// Each action asks first, says what it removes and where, and says
/// afterwards whether the service heard it: offline is "nothing was
/// forgotten", never a quiet success.
class XerviceSection extends StatefulWidget {
  const XerviceSection({super.key, required this.ctx});

  /// The `ctx` field, for whether anybody is signed in.
  final ValueListenable<Map<String, dynamic>?> ctx;

  static const String forgetLikesTitle = 'Forget my likes everywhere';
  static const String forgetLikesSubtitle =
      'Your likes, dislikes and "Not interested" titles, on this device and '
      'on every device signed in to this account.';
  static const String forgetLikesQuestion =
      'Forget every like, dislike and "Not interested" on every device '
      'signed in to this account? This cannot be undone.';
  static const String forgetDriveTitle = 'Forget my Drive grants everywhere';
  static const String forgetDriveSubtitle =
      'The Google Drive grant kept for this account, which a device with '
      'none of its own takes at start.';
  static const String forgetDriveQuestion =
      'Forget the Google Drive grant kept for this account? Devices that '
      'already have one keep it, and no device takes it from xtremio-xervice '
      'again until the next pairing.';

  /// Where a Google account's grants to apps are revoked.
  static const String googlePermissions =
      'https://myaccount.google.com/permissions';
  static const String revokeThere =
      'xtremio-xervice no longer keeps your Drive grant. The grant itself '
      'lives with Google until you remove this app at '
      'myaccount.google.com/permissions -- that is where it is revoked, for '
      'every device at once.';
  static const String openPermissions = 'Open Google permissions';

  static const String forgotten = 'Forgotten on every device.';
  static const String notReached =
      'xtremio-xervice could not be reached. Nothing was forgotten.';

  @override
  State<XerviceSection> createState() => _XerviceSectionState();
}

class _XerviceSectionState extends State<XerviceSection> {
  bool _busy = false;

  /// Asks [question], and on a yes runs [forget] and says how it went --
  /// with [after] instead of the plain line when it went, if given.
  Future<void> _confirmThen(
    String question,
    Future<bool> Function() forget, {
    Future<void> Function()? after,
  }) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(question),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _busy = true);
    final done = await forget();
    if (!mounted) return;
    setState(() => _busy = false);
    if (done && after != null) return after();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          done ? XerviceSection.forgotten : XerviceSection.notReached,
        ),
      ),
    );
  }

  /// After the vault forgot the grant: where the grant itself is revoked,
  /// and the way there.
  Future<void> _pointAtGoogle() async {
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: const Text(XerviceSection.revokeThere),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Done'),
          ),
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(XerviceSection.openPermissions),
          ),
        ],
      ),
    );
    if (open == true && mounted) {
      await openInBrowser(context, XerviceSection.googlePermissions);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = XerviceScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    return ValueListenableBuilder(
      valueListenable: widget.ctx,
      builder: (context, ctx, _) {
        if (stremioAuthKeyOf(ctx) == null) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.sentiment_neutral_outlined),
              title: const Text(XerviceSection.forgetLikesTitle),
              subtitle: const Text(XerviceSection.forgetLikesSubtitle),
              enabled: !_busy,
              onTap: () => _confirmThen(
                XerviceSection.forgetLikesQuestion,
                scope.faces.forgetEverywhere,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_to_drive_outlined),
              title: const Text(XerviceSection.forgetDriveTitle),
              subtitle: const Text(XerviceSection.forgetDriveSubtitle),
              enabled: !_busy,
              onTap: () => _confirmThen(
                XerviceSection.forgetDriveQuestion,
                scope.driveVault.forgetEverywhere,
                after: _pointAtGoogle,
              ),
            ),
          ],
        );
      },
    );
  }
}
