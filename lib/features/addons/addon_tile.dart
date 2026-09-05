import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../widgets/focusable_tile.dart';
import 'addon_widgets.dart';

/// One addon in a list: logo, name and version, description, the types it
/// serves, an optional [status] line under them, plus whatever [trailing]
/// the list wants (a menu, a button).
///
/// On a television it is a [FocusableTile] like every other list of things
/// in the app, so the D-pad's focus is drawn as a ring and the tile it is
/// on scrolls itself into view; off one it is the plain ink well it always
/// was.
class AddonTile extends StatelessWidget {
  const AddonTile({
    super.key,
    required this.addon,
    this.trailing,
    this.status,
    this.onTap,
    this.memoryId,
    this.defaultFocus = false,
  });

  final AddonDescriptor addon;
  final Widget? trailing;

  /// Drawn under the type labels: the Installed list puts the addon's
  /// health verdict here. Nothing when there is nothing to say about it.
  ///
  /// On a television it is drawn under the *tile* instead, outside it. The
  /// tile takes focus as a whole, so directional traversal has nothing
  /// inside it to step to, and its [RemotePress] takes select before any
  /// descendant's own activation runs -- a status that opens something,
  /// like the health verdict, would be drawn and dead. Beside the thing is
  /// where such a control goes (see `TvTextField.onClear`), and here that
  /// means beneath: a verdict belongs under the addon it judges, and a
  /// list a remote walks downwards gains one stop rather than a stop off
  /// to one side of another.
  final Widget? status;

  /// Where the status sits when it is drawn under the tile: lined up with
  /// the text column, past the logo, so it still reads as belonging to the
  /// addon above it rather than to the list.
  static const double statusIndent = 16 + AddonLogo.defaultSize + 12;

  final VoidCallback? onTap;

  /// See [FocusableTile.memoryId] and [FocusableTile.defaultFocus].
  final String? memoryId;
  final bool defaultFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manifest = addon.manifest;
    final description = manifest.description;
    final beneath = DeviceScope.isTv(context) ? status : null;
    final tile = FocusableTile(
      onTap: onTap,
      memoryId: memoryId,
      defaultFocus: defaultFocus,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AddonLogo(url: manifest.logo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          manifest.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'v${manifest.version}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  if (description != null && description.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (manifest.types.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    AddonTypeLabels(types: manifest.types),
                  ],
                  if (status != null && beneath == null) ...[
                    const SizedBox(height: 6),
                    Align(alignment: Alignment.centerLeft, child: status!),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
      ),
    );
    if (beneath == null) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        tile,
        Padding(
          padding: const EdgeInsets.fromLTRB(statusIndent, 0, 12, 12),
          child: beneath,
        ),
      ],
    );
  }
}
