import 'package:flutter/material.dart';

import '../core/state/meta_item_preview.dart';

/// A poster with the item's name underneath; falls back to a neutral box
/// when there is no poster or it fails to load.
class PosterTile extends StatelessWidget {
  const PosterTile({super.key, required this.item, this.onTap});

  final MetaItemPreview item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final poster = item.poster;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: poster == null
                    ? const _PosterFallback()
                    : Image.network(
                        poster,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (_, _, _) => const _PosterFallback(),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback();

  @override
  Widget build(BuildContext context) =>
      const Center(child: Icon(Icons.movie_outlined, size: 32));
}
