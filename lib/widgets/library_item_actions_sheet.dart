import 'package:flutter/material.dart';

import '../core/core.dart';
import '../shell/device_profile.dart';

/// What the long-press menu on a library item ([LibraryItemActionsSheet])
/// can ask the engine to do.
enum LibraryItemAction { markWatched, rewind, toggleNotifications, remove }

/// The engine action [action] is, for [item].
CoreAction libraryItemActionFor(
  LibraryItemAction action,
  LibraryItemView item,
) => switch (action) {
  LibraryItemAction.remove => CoreActions.removeFromLibrary(item.id),
  LibraryItemAction.markWatched => CoreActions.libraryItemMarkAsWatched(
    item.id,
    watched: !item.isWatched,
  ),
  LibraryItemAction.rewind => CoreActions.rewindLibraryItem(item.id),
  LibraryItemAction.toggleNotifications =>
    CoreActions.toggleLibraryItemNotifications(
      item.id,
      disabled: !item.notificationsDisabled,
    ),
};

/// The long-press menu of one library item: mark watched, rewind, toggle
/// notifications, remove. Shared by the Library screen and, for an item
/// the Continue-watching row shows that is also in the library, the
/// Board (see [showContinueWatchingActions]) -- the same menu either way,
/// so opening it from the Board loses none of what opening it from the
/// Library screen offers.
class LibraryItemActionsSheet extends StatelessWidget {
  const LibraryItemActionsSheet({super.key, required this.item});

  final LibraryItemView item;

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
        ],
      ),
    );
  }
}

/// The long-press menu on a Continue-watching tile for a title that was
/// never added to the library (or was removed from it): the one thing
/// Stremio does for "take this off Continue watching" without adding it to
/// the library or marking it watched.
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
/// also what [LibraryItemActionsSheet]'s own "Rewind" sends, so a tile
/// already in the library keeps behaving exactly as it does from the
/// Library screen (see [showContinueWatchingActions]).
class ContinueWatchingRemoveSheet extends StatelessWidget {
  const ContinueWatchingRemoveSheet({super.key, required this.item});

  final LibraryItemView item;

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
          autofocus: DeviceScope.isTv(context),
          leading: const Icon(Icons.close),
          title: const Text('Remove from Continue watching'),
          onTap: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
}

/// Opens the long-press menu for a Continue-watching tile and dispatches
/// whatever it picks: [LibraryItemActionsSheet] -- the full library menu,
/// entries unchanged -- when [item] is actually in the library, so opening
/// it from the Board offers nothing less than opening it from the Library
/// screen would; [ContinueWatchingRemoveSheet] otherwise, whose one entry
/// rewinds the item (see its doc for why that removes it from Continue
/// watching without touching the library).
Future<void> showContinueWatchingActions(
  BuildContext context,
  CoreClient? client,
  LibraryItemView item,
) async {
  if (item.isInLibrary) {
    final action = await showModalBottomSheet<LibraryItemAction>(
      context: context,
      builder: (_) => LibraryItemActionsSheet(item: item),
    );
    if (action != null) client?.dispatch(libraryItemActionFor(action, item));
    return;
  }
  final remove = await showModalBottomSheet<bool>(
    context: context,
    builder: (_) => ContinueWatchingRemoveSheet(item: item),
  );
  if (remove ?? false) {
    client?.dispatch(CoreActions.rewindLibraryItem(item.id));
  }
}
