import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../widgets/content_type_label.dart';
import '../../widgets/filter_controls.dart';
import '../../widgets/library_item_tile.dart';
import '../details/meta_details_screen.dart';
import '../downloads/downloads_screen.dart';

/// The library (`library`, a `LibraryWithFilters<NotRemovedFilter>`): every
/// title added or followed, filtered by type and sorted.
///
/// On mount it dispatches `Load LibraryWithFilters` for every type sorted by
/// last watched; the engine answers with `selectable` (the types present,
/// the six sorts, the next page) where every entry carries the request that
/// selects it, and the filter row dispatches those verbatim. `catalog` is
/// cumulative — `LoadNextPage` makes the engine publish a longer list, so
/// the grid replaces its items rather than appending. Item actions (remove,
/// mark watched, rewind, notifications) are `Ctx` actions; the engine
/// refreshes this field on its own after each. The field is unloaded on
/// dispose; the anonymous library is shown with a hint to sign in, and a
/// signed-in profile gets a "Sync now" button.
///
/// The filter row also carries the way to the [DownloadsScreen]: what is
/// kept on the device is a view of the library rather than a place of its
/// own, and a chip next to the type filters is where one would look for it.
///
/// On a TV the filter row and the grid are separate [FocusTraversalGroup]s,
/// the tiles remember which one had focus for the shell's per-tab memory,
/// the remote's menu key or a held select opens an item's actions (what a
/// long press does on a phone), and the sheet puts focus on its first
/// action so the D-pad can walk it.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  /// From this width on, types are a segmented button rather than chips.
  static const double wideBreakpoint = 720;

  /// The initial request: every type, last watched first, page 1.
  static const LibraryRequest initialRequest = LibraryRequest();

  /// Display names of `library_with_filters::Sort`, in the engine's order.
  static String sortLabel(String sort) => switch (sort) {
    LibrarySort.lastWatched => 'Last watched',
    LibrarySort.name => 'Name (A–Z)',
    LibrarySort.nameReverse => 'Name (Z–A)',
    LibrarySort.timesWatched => 'Times watched',
    LibrarySort.watched => 'Watched',
    LibrarySort.notWatched => 'Not watched',
    _ => capitalise(sort),
  };

  /// Label of the `type: null` entry.
  static const String allTypesLabel = 'All';

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _library;
  CoreFieldNotifier? _ctx;
  StreamSubscription<CoreEvent>? _events;
  int _nextPageRequestedAt = -1;

  /// A `SyncLibraryWithAPI` is in flight. The engine has no state for it,
  /// so this is cleared by the `LibrarySyncWithAPIPlanned` event (or the
  /// `Error` whose source is that event).
  bool _syncing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _library?.dispose();
      _ctx?.dispose();
      _events?.cancel();
      _client = client;
      _library = CoreFieldNotifier(client, CoreField.library);
      _ctx = CoreFieldNotifier(client, CoreField.ctx);
      _events = client.events.listen(_onEvent);
      _nextPageRequestedAt = -1;
      client.dispatch(CoreActions.loadLibrary(LibraryScreen.initialRequest));
    }
  }

  @override
  void dispose() {
    _client?.dispatch(CoreActions.unload(CoreField.library));
    _events?.cancel();
    _library?.dispose();
    _ctx?.dispose();
    super.dispose();
  }

  void _onEvent(CoreEvent event) {
    if (!_syncing || event is! RuntimeCoreEvent) return;
    final settled = switch (event.name) {
      'LibrarySyncWithAPIPlanned' => true,
      'Error' => _errorSource(event) == 'LibrarySyncWithAPIPlanned',
      _ => false,
    };
    if (settled && mounted) setState(() => _syncing = false);
  }

  /// The `source.event` of an `Error` event, when it has one. Only the name
  /// is read: the args of an error can carry account details.
  static String? _errorSource(RuntimeCoreEvent event) {
    final args = event.args;
    if (args is! Map<String, dynamic>) return null;
    final source = args['source'];
    return source is Map<String, dynamic> ? source['event'] as String? : null;
  }

  void _select(LibraryRequest request) {
    _nextPageRequestedAt = -1;
    _client?.dispatch(CoreActions.loadLibrary(request));
  }

  bool _onScroll(ScrollNotification notification, LibraryState state) {
    if (notification.metrics.extentAfter < 600 &&
        state.hasNextPage &&
        _nextPageRequestedAt != state.items.length) {
      _nextPageRequestedAt = state.items.length;
      _client?.dispatch(CoreActions.loadLibraryNextPage());
    }
    return false;
  }

  void _sync() {
    if (_syncing) return;
    setState(() => _syncing = true);
    _client?.dispatch(CoreActions.syncLibraryWithAPI());
  }

  void _openDownloads() {
    Navigator.of(context).push(DownloadsScreen.route());
  }

  void _open(LibraryItemView item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MetaDetailsScreen(
          type: item.type,
          id: item.id,
          videoId: item.videoId,
        ),
      ),
    );
  }

  Future<void> _showActions(LibraryItemView item) async {
    final action = await showModalBottomSheet<_ItemAction>(
      context: context,
      builder: (_) => _ItemActionsSheet(item: item),
    );
    if (action == null) return;
    _client?.dispatch(switch (action) {
      _ItemAction.remove => CoreActions.removeFromLibrary(item.id),
      _ItemAction.markWatched => CoreActions.libraryItemMarkAsWatched(
        item.id,
        watched: !item.isWatched,
      ),
      _ItemAction.rewind => CoreActions.rewindLibraryItem(item.id),
      _ItemAction.toggleNotifications =>
        CoreActions.toggleLibraryItemNotifications(
          item.id,
          disabled: !item.notificationsDisabled,
        ),
    });
  }

  bool get _isLoggedIn {
    final ctx = _ctx?.value;
    return ctx != null && ProfileState.fromCtx(ctx).isLoggedIn;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_library!, _ctx!]),
      builder: (context, _) {
        final json = _library!.value;
        final state = json == null ? null : LibraryState.fromJson(json);
        final isLoggedIn = _isLoggedIn;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Library'),
            actions: [
              if (isLoggedIn)
                _syncing
                    ? const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        tooltip: 'Sync now',
                        icon: const Icon(Icons.sync),
                        onPressed: _sync,
                      ),
            ],
          ),
          // The filter row stays as long as the library has anything in it:
          // a type filter that matches nothing must keep "All" one tap away.
          body: Column(
            children: [
              if (state != null && state.isLoaded && !state.isLibraryEmpty)
                _tvGroup(
                  context,
                  _FilterRow(
                    selectable: state.selectable,
                    onSelect: _select,
                    onDownloads: _openDownloads,
                  ),
                ),
              if (!isLoggedIn && state != null && !state.isLibraryEmpty)
                const _SignInHint(),
              Expanded(
                child: state == null || !state.isLoaded
                    ? const Center(child: CircularProgressIndicator())
                    : state.isFilteredEmpty
                    ? _EmptyFilter(type: state.selected!.type!)
                    : state.isEmpty
                    ? _EmptyLibrary(isLoggedIn: isLoggedIn)
                    : _tvGroup(context, _buildGrid(state)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGrid(LibraryState state) {
    final items = state.items;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) => _onScroll(n, state),
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 160,
          childAspectRatio: 0.56,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return LibraryItemTile(
            item: item,
            onTap: () => _open(item),
            onLongPress: () => _showActions(item),
            memoryId: item.id,
          );
        },
      ),
    );
  }

  /// [child] as its own traversal group on a TV; [child] itself elsewhere.
  static Widget _tvGroup(BuildContext context, Widget child) =>
      DeviceScope.isTv(context) ? FocusTraversalGroup(child: child) : child;
}

/// The types present in the library and the sort. Stateless: [onSelect]
/// gets the request the engine attached to the chosen entry.
///
/// The "Downloaded" chip is not one of those: nothing in the engine knows
/// about downloads, so it opens the Downloads screen rather than filtering
/// this grid.
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.selectable,
    required this.onSelect,
    required this.onDownloads,
  });

  final LibrarySelectable selectable;
  final ValueChanged<LibraryRequest> onSelect;
  final VoidCallback onDownloads;

  static const String downloadedLabel = 'Downloaded';

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.sizeOf(context).width >= LibraryScreen.wideBreakpoint;
    final types = [
      for (final type in selectable.types)
        FilterOption(
          label: switch (type.type) {
            null => LibraryScreen.allTypesLabel,
            final type => contentTypeLabel(type),
          },
          selected: type.selected,
          request: type.request,
        ),
    ];
    final sorts = [
      for (final sort in selectable.sorts)
        FilterOption(
          label: LibraryScreen.sortLabel(sort.sort),
          selected: sort.selected,
          request: sort.request,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (types.isNotEmpty)
            isWide
                ? FilterSegments(options: types, onSelect: onSelect)
                : FilterChips(options: types, onSelect: onSelect),
          if (sorts.isNotEmpty)
            FilterMenu(label: 'Sort', options: sorts, onSelect: onSelect),
          ActionChip(
            avatar: const Icon(Icons.download_done_outlined, size: 18),
            label: const Text(downloadedLabel),
            onPressed: onDownloads,
          ),
        ],
      ),
    );
  }
}

enum _ItemAction { remove, markWatched, rewind, toggleNotifications }

/// The long-press menu of one item.
class _ItemActionsSheet extends StatelessWidget {
  const _ItemActionsSheet({required this.item});

  final LibraryItemView item;

  @override
  Widget build(BuildContext context) {
    void pick(_ItemAction action) => Navigator.of(context).pop(action);
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
            onTap: () => pick(_ItemAction.markWatched),
          ),
          ListTile(
            leading: const Icon(Icons.replay_outlined),
            title: const Text('Rewind'),
            onTap: () => pick(_ItemAction.rewind),
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
            onTap: () => pick(_ItemAction.toggleNotifications),
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_remove_outlined),
            title: const Text('Remove from library'),
            onTap: () => pick(_ItemAction.remove),
          ),
        ],
      ),
    );
  }
}

/// Shown above a non-empty anonymous library.
class _SignInHint extends StatelessWidget {
  const _SignInHint();

  static const String text = 'Sign in to sync';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$text: this library lives on this device only '
              '(Settings → Account).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the selected type matches nothing while the library is not
/// empty; the filter row above it still offers "All".
class _EmptyFilter extends StatelessWidget {
  const _EmptyFilter({required this.type});

  final String type;

  /// The message for [type] (`'No movies in your library'`; an acronym
  /// such as `TV` keeps its case).
  static String message(String type) {
    final label = contentTypeLabel(type);
    final word = label == label.toUpperCase() ? label : label.toLowerCase();
    return 'No $word in your library';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_list_off_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(message(type), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Pick "${LibraryScreen.allTypesLabel}" above to see every '
              'title you have.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.isLoggedIn});

  final bool isLoggedIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('Your library is empty', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              isLoggedIn
                  ? 'Add titles from their details page and they show '
                        'up here on every device.'
                  : '${_SignInHint.text} — sign in to your Stremio account '
                        'in Settings to get your library on this device.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
