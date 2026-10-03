import 'package:flutter/material.dart';

import 'app_updates.dart';
import 'update_dialog.dart';

/// Settings' "Check for updates": asks for the latest release now, past the
/// once-a-day limit the start-up look keeps, and says what it found --
/// the update dialog for a newer release, a line for everything else,
/// "up to date" included.
class CheckForUpdatesTile extends StatefulWidget {
  const CheckForUpdatesTile({super.key, required this.updates});

  final AppUpdates updates;

  static const String title = 'Check for updates';

  /// What a check that found nothing newer says.
  static String upToDate(String version) => 'xtremio $version is up to date.';

  @override
  State<CheckForUpdatesTile> createState() => _CheckForUpdatesTileState();
}

class _CheckForUpdatesTileState extends State<CheckForUpdatesTile> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    final result = await widget.updates.check();
    if (!mounted) return;
    setState(() => _checking = false);
    if (result is UpdateAvailable) {
      await showUpdateDialog(
        context,
        updates: widget.updates,
        release: result.release,
      );
      return;
    }
    final current = widget.updates.identity.parsed;
    final message = switch (result) {
      UpdateAvailable() || UpdateNotChecked() => null,
      UpdateUpToDate(:final release) =>
        current == null || current == release.version
            ? CheckForUpdatesTile.upToDate('${release.version}')
            : 'This is xtremio $current; the latest release is '
                  '${release.version}.',
      UpdateUnversioned(:final release) =>
        'This build carries no version to compare. The latest release is '
            '${release.version}.',
      UpdateCheckFailed(:final message) =>
        'Could not check for updates: $message.',
    };
    if (message != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.updates.identity.parsed;
    return ListTile(
      key: const ValueKey('setting-check-updates'),
      leading: const Icon(Icons.system_update_outlined),
      title: const Text(CheckForUpdatesTile.title),
      subtitle: Text(
        _checking
            ? 'Checking…'
            : current == null
            ? 'This build carries no version'
            : 'This is xtremio $current',
      ),
      onTap: _check,
    );
  }
}
