import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../widgets/focusable_tile.dart';
import 'addon_widgets.dart';

/// One addon in a list: logo, name and version, description, the types it
/// serves, plus whatever [trailing] the list wants (a menu, a button).
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
    this.onTap,
    this.memoryId,
    this.defaultFocus = false,
  });

  final AddonDescriptor addon;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// See [FocusableTile.memoryId] and [FocusableTile.defaultFocus].
  final String? memoryId;
  final bool defaultFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manifest = addon.manifest;
    final description = manifest.description;
    return FocusableTile(
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
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
      ),
    );
  }
}
