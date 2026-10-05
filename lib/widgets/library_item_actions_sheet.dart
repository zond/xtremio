import 'package:flutter/material.dart';

import '../core/core.dart';
import '../shell/device_profile.dart';

/// What the long-press menu on a library item ([LibraryItemActionsSheet])
/// can ask the engine to do.
enum LibraryItemAction {
  markWatched,
  rewind,
  toggleNotifications,
  remove,

  /// Offered only on a Continue-watching tile, and confirmed first
  /// ([showContinueWatchingActions]).
  removeFromContinueWatching,
}

/// The engine actions [action] is, for [item], in the order they are sent.
List<CoreAction> libraryItemActionsFor(
  LibraryItemAction action,
  LibraryItemView item,
) => switch (action) {
  LibraryItemAction.remove => [CoreActions.removeFromLibrary(item.id)],
  LibraryItemAction.markWatched => [
    CoreActions.libraryItemMarkAsWatched(item.id, watched: !item.isWatched),
  ],
  LibraryItemAction.rewind => [CoreActions.rewindLibraryItem(item.id)],
  LibraryItemAction.toggleNotifications => [
    CoreActions.toggleLibraryItemNotifications(
      item.id,
      disabled: !item.notificationsDisabled,
    ),
  ],
  LibraryItemAction.removeFromContinueWatching =>
    CoreActions.dismissFromContinueWatching(item.id),
};

/// The long-press menu of one library item: mark watched, rewind, toggle
/// notifications, remove. Shared by the Library screen and, for an item
/// the Continue-watching row shows that is also in the library, the
/// Board (see [showContinueWatchingActions]) -- the same menu either way,
/// so opening it from the Board loses none of what opening it from the
/// Library screen offers.
class LibraryItemActionsSheet extends StatelessWidget {
  const LibraryItemActionsSheet({
    super.key,
    required this.item,
    this.fromContinueWatching = false,
  });

  final LibraryItemView item;

  /// Opened from a Continue-watching tile, which adds "Remove from Continue
  /// watching" to the menu.
  final bool fromContinueWatching;

  @override
  Widget build(BuildContext context) {
    void pick(LibraryItemAction action) => Navigator.of(context).pop(action);
    // A remote has nothing to point with: the first action takes focus so
    // up, down and select work from the start.
    final isTv = DeviceScope.isTv(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            autofocus: isTv,
            leading: Icon(
              item.isWatched
                  ? Icons.remove_done_outlined
                  : Icons.done_all_outlined,
            ),
            title: Text(
              item.isWatched ? 'Mark as not watched' : 'Mark as watched',
            ),
            onTap: () => pick(LibraryItemAction.markWatched),
          ),
          ListTile(
            leading: const Icon(Icons.replay_outlined),
            title: const Text('Rewind'),
            onTap: () => pick(LibraryItemAction.rewind),
          ),
          ListTile(
            leading: Icon(
              item.notificationsDisabled
                  ? Icons.notifications_outlined
                  : Icons.notifications_off_outlined,
            ),
            title: Text(
              item.notificationsDisabled
                  ? 'Enable notifications'
                  : 'Disable notifications',
            ),
            onTap: () => pick(LibraryItemAction.toggleNotifications),
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_remove_outlined),
            title: const Text('Remove from library'),
            onTap: () => pick(LibraryItemAction.remove),
          ),
          if (fromContinueWatching)
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text(ContinueWatchingRemoveSheet.removeLabel),
              onTap: () => pick(LibraryItemAction.removeFromContinueWatching),
            ),
        ],
      ),
    );
  }
}

/// The confirmation a Continue-watching tile asks before it is taken off
/// the row: a long press is easily held a moment too long, and what it
/// would lose is the place in a film. So nothing is sent until "Remove
/// from Continue watching" is chosen here, and on a television the remote
/// starts on Cancel. It is the whole long-press menu of a title that was
/// never added to the library (or was removed from it), and the second
/// step of the full menu's entry for one that is in it.
///
/// `LibraryItem::is_in_continue_watching` (the pinned stremio-core,
/// `src/types/library/library_item.rs`) is `type != "other" && (!removed
/// || temp) && state.time_offset > 0` -- membership turns on
/// `time_offset` alone once `temp` is set, which a title never added to
/// the library always has. `RewindLibraryItem` (`ActionCtx::
/// RewindLibraryItem`, `src/models/ctx/update_library.rs`) sets exactly
/// that field to zero and touches nothing else -- not `removed`, not
/// `temp`, not `timesWatched` -- so it drops the title out of Continue
/// watching without adding it to the library or marking it watched. It is
/// also what [LibraryItemActionsSheet]'s own "Rewind" sends. A series is
/// kept on the row by new-episode notifications as well, so the
/// notifications are dismissed with it, as Stremio's own clients do
/// ([CoreActions.dismissFromContinueWatching]).
class ContinueWatchingRemoveSheet extends StatelessWidget {
  const ContinueWatchingRemoveSheet({super.key, required this.item});

  final LibraryItemView item;

  static const String removeLabel = 'Remove from Continue watching';

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.close),
          title: const Text(removeLabel),
          onTap: () => Navigator.of(context).pop(true),
        ),
        ListTile(
          autofocus: DeviceScope.isTv(context),
          leading: const Icon(Icons.arrow_back),
          title: const Text('Cancel'),
          onTap: () => Navigator.of(context).pop(false),
        ),
      ],
    ),
  );
}

/// Opens the long-press menu for a Continue-watching tile and dispatches
/// whatever it picks: [LibraryItemActionsSheet] -- the full library menu,
/// with "Remove from Continue watching" added -- when [item] is actually in
/// the library, so opening it from the Board offers nothing less than
/// opening it from the Library screen would; [ContinueWatchingRemoveSheet]
/// otherwise. Removing from Continue watching is confirmed on
/// [ContinueWatchingRemoveSheet] either way (see its doc for why it takes
/// the title off the row without touching the library).
///
/// Answers whether the item was taken off the row.
Future<bool> showContinueWatchingActions(
  BuildContext context,
  CoreClient? client,
  LibraryItemView item,
) async {
  if (item.isInLibrary) {
    final action = await showModalBottomSheet<LibraryItemAction>(
      context: context,
      builder: (_) =>
          LibraryItemActionsSheet(item: item, fromContinueWatching: true),
    );
    if (action == null) return false;
    if (action != LibraryItemAction.removeFromContinueWatching) {
      for (final each in libraryItemActionsFor(action, item)) {
        client?.dispatch(each);
      }
      return false;
    }
    if (!context.mounted) return false;
  }
  final remove = await showModalBottomSheet<bool>(
    context: context,
    builder: (_) => ContinueWatchingRemoveSheet(item: item),
  );
  if (!(remove ?? false)) return false;
  for (final each in CoreActions.dismissFromContinueWatching(item.id)) {
    client?.dispatch(each);
  }
  return true;
}
