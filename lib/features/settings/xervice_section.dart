import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/external_link.dart';
import '../../widgets/explained.dart';

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
  static const String forgetLikesExplanation =
      'Your likes and dislikes are saved with your account.';
  static const String forgetLikesQuestion =
      'Forget every like, dislike and "Not interested" on every device '
      'signed in to this account? This cannot be undone.';
  static const String forgetDriveTitle = 'Forget my Drive access everywhere';
  static const String forgetDriveExplanation =
      'Your Drive link is saved with your account.';
  static const String forgetDriveQuestion =
      'Forget the Google Drive access saved with this account? Devices that '
      'already have it keep it. No other device gets it until you link '
      'Drive again.';

  /// Where a Google account's grants to apps are revoked.
  static const String googlePermissions =
      'https://myaccount.google.com/permissions';
  static const String revokeThere =
      'Your Drive access is no longer saved with your account. Google still '
      'lets this app in until you remove it at '
      'myaccount.google.com/permissions. Removing it there ends access on '
      'every device at once.';
  static const String openPermissions = 'Open Google permissions';

  static const String forgotten = 'Forgotten on every device.';
  static const String notReached =
      "Xtremio's service could not be reached. Nothing was forgotten.";

  @override
  State<XerviceSection> createState() => _XerviceSectionState();
}

class _XerviceSectionState extends State<XerviceSection> {
  bool _busy = false;

  /// Asks [question], and on a yes runs [forget] and says how it went. When it
  /// went and [after] is given, [after] replaces the plain line.
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
            Explained(
              title: XerviceSection.forgetLikesTitle,
              explanation: XerviceSection.forgetLikesExplanation,
              child: ListTile(
                leading: const ExplainIcon(
                  Icon(Icons.sentiment_neutral_outlined),
                ),
                title: const Text(XerviceSection.forgetLikesTitle),
                enabled: !_busy,
                onTap: () => _confirmThen(
                  XerviceSection.forgetLikesQuestion,
                  scope.faces.forgetEverywhere,
                ),
              ),
            ),
            Explained(
              title: XerviceSection.forgetDriveTitle,
              explanation: XerviceSection.forgetDriveExplanation,
              child: ListTile(
                leading: const ExplainIcon(Icon(Icons.add_to_drive_outlined)),
                title: const Text(XerviceSection.forgetDriveTitle),
                enabled: !_busy,
                onTap: () => _confirmThen(
                  XerviceSection.forgetDriveQuestion,
                  scope.driveVault.forgetEverywhere,
                  after: _pointAtGoogle,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
