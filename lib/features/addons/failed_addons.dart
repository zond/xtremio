/// The addons that could not answer, and the two things to do about one.
///
/// Lives here rather than on the details screen because a failure looks the
/// same wherever it is reported: a screen that asks several addons at once
/// and shows only what came back — the sources list, the board — owes the
/// viewer an account of the rest.
library;

import 'package:flutter/material.dart';

import '../../core/core.dart';
import 'addon_details_screen.dart';

/// One addon that answered a request with an error, and the installed addon
/// behind the manifest URL it was asked at.
///
/// A failed request carries the transport URL and nothing else, so without
/// the profile a dead addon can only be named by its host — which is
/// exactly the "a lot of 404s from domains I do not recognise" problem.
/// With it, the row says which of the installed addons is broken and can
/// offer to drop it.
final class AddonFailure {
  const AddonFailure({
    required this.transportUrl,
    required this.addon,
    required this.fallbackName,
    required this.message,
  });

  /// The manifest URL the request was made against.
  final String transportUrl;

  /// The installed addon at [transportUrl]; null when nothing is installed
  /// under it any more (the state is a moment older than the profile).
  final AddonDescriptor? addon;

  /// What to call it when the profile has nothing under [transportUrl]:
  /// whatever the failing request could be labelled by, usually its host.
  final String fallbackName;

  /// What the addon said, already made readable by `LoadableError.message`.
  final String message;

  /// The addon's own name, falling back to how the request was labelled.
  String get name => addon?.manifest.name ?? fallbackName;

  /// Cinemeta and the local addon cannot be uninstalled, and neither can
  /// one that is not in the profile to begin with.
  bool get isRemovable => addon != null && !addon!.isProtected;
}

/// The addons behind [rows] -- the catalog rows a screen dropped because
/// their addon could not answer -- one entry each, in the order they were
/// first met.
///
/// One entry per addon rather than per catalog: an entry's actions are
/// about the addon, so a host that took two of its own catalogs down would
/// otherwise offer to uninstall itself twice. What the summary line counts
/// is the screen's own business and need not be this many.
List<AddonFailure> addonFailuresOf(
  Iterable<CatalogRow> rows,
  ProfileState? profile,
) {
  final byUrl = <String, AddonFailure>{};
  for (final row in rows) {
    final url = row.firstRequest.base;
    byUrl.putIfAbsent(
      url,
      () => AddonFailure(
        transportUrl: url,
        addon: profile?.installedAddon(url),
        fallbackName: row.addonName,
        message: row.error?.message ?? '',
      ),
    );
  }
  return byUrl.values.toList();
}

/// The addons that failed, below whatever did arrive.
///
/// One failure is the row itself, unless [collapseSingle] says otherwise.
/// Several — a profile full of dead mirrors answers every request with
/// the same wall of 404s — collapse into a single summary row naming
/// them, which expands into the same rows, so what did work stays the
/// first thing on screen.
class FailedAddonsSection extends StatefulWidget {
  const FailedAddonsSection({
    super.key,
    required this.failures,
    required this.summaryLabel,
    required this.locked,
    required this.onCheck,
    required this.onUninstall,
    this.collapseSingle = false,
  });

  final List<AddonFailure> failures;

  /// The collapsed line's text. The caller counts what its viewer lost —
  /// addons on the details screen, catalogs on the board — and that need
  /// not be the number of cards underneath.
  final String summaryLabel;

  /// `profile.addonsLocked`: every install and uninstall fails until the
  /// addon collection has been pulled, so the action is shown disabled
  /// rather than offered and refused.
  final bool locked;

  final ValueChanged<AddonFailure> onCheck;

  /// Only called for a failure whose [AddonFailure.isRemovable] holds.
  final ValueChanged<AddonFailure> onUninstall;

  /// Collapse even a lone failure behind [summaryLabel]. What the section
  /// sits under decides it: under the streams of the title the viewer is
  /// looking at, the one thing that went wrong is worth stating outright;
  /// at the foot of a board they scrolled past, one line is enough.
  final bool collapseSingle;

  static const String checkLabel = 'Check addon';
  static const String uninstallLabel = 'Uninstall';

  /// The summary row of [count] addons that did not answer.
  static String addonsLabel(int count) => '$count addons did not answer';

  @override
  State<FailedAddonsSection> createState() => _FailedAddonsSectionState();
}

class _FailedAddonsSectionState extends State<FailedAddonsSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failures = widget.failures;
    Widget card(AddonFailure failure) => AddonFailureCard(
      failure: failure,
      locked: widget.locked,
      onCheck: () => widget.onCheck(failure),
      onUninstall: () => widget.onUninstall(failure),
    );
    if (failures.length == 1 && !widget.collapseSingle) {
      return card(failures.single);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          leading: Icon(
            Icons.cloud_off_outlined,
            color: theme.colorScheme.error,
          ),
          title: Text(widget.summaryLabel),
          subtitle: Text(
            [for (final failure in failures) failure.name].join(', '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded)
          for (final failure in failures) card(failure),
      ],
    );
  }
}

/// One dead addon: what it is called, what it said, and the two things to
/// do about it — look at its manifest (the details screen fetches it, which
/// is the reachability test) or drop it from the profile.
class AddonFailureCard extends StatelessWidget {
  const AddonFailureCard({
    super.key,
    required this.failure,
    required this.locked,
    required this.onCheck,
    required this.onUninstall,
  });

  final AddonFailure failure;
  final bool locked;
  final VoidCallback onCheck;
  final VoidCallback onUninstall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 20,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(failure.name, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      failure.message,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: onCheck,
                  icon: const Icon(Icons.troubleshoot),
                  label: const Text(FailedAddonsSection.checkLabel),
                ),
                if (failure.isRemovable)
                  TextButton.icon(
                    onPressed: locked ? null : onUninstall,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text(FailedAddonsSection.uninstallLabel),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Uninstalling from a screen that is about something else changes the
/// whole profile, so it is asked about first.
class UninstallAddonDialog extends StatelessWidget {
  const UninstallAddonDialog({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Uninstall $name?'),
    content: const Text(
      'It stops being asked for streams everywhere in the app. You can '
      'install it again from Addons with its manifest URL.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text(FailedAddonsSection.uninstallLabel),
      ),
    ],
  );
}

/// Opens [transportUrl]'s addon details. Its manifest fetch is the
/// reachability test a failing addon asks for, and Install / Uninstall are
/// there too.
void openAddonDetails(BuildContext context, String transportUrl) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'addon-details'),
      builder: (_) => AddonDetailsScreen(transportUrl: transportUrl),
    ),
  );
}

/// Drops [addon] from the profile once the user has said so. Uninstalling
/// is a profile-wide change made from a screen about something else, so it
/// is never a single tap; the engine refreshes `ctx` itself, and whatever
/// named the addon stays on screen until the next `Load` stops asking it.
Future<void> confirmAndUninstallAddon(
  BuildContext context,
  CoreClient? client,
  AddonDescriptor addon,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => UninstallAddonDialog(name: addon.manifest.name),
  );
  if (confirmed != true || !context.mounted) return;
  client?.dispatch(CoreActions.uninstallAddon(addon));
  messenger?.showSnackBar(
    SnackBar(content: Text('Uninstalled ${addon.manifest.name}')),
  );
}
