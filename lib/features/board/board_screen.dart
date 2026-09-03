import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/library_item_tile.dart';
import '../../widgets/poster_tile.dart';
import '../addons/addons_screen.dart';
import '../details/meta_details_screen.dart';
import '../discover/discover_screen.dart';

/// Home: a "Continue watching" row over `continue_watching_preview` followed
/// by one horizontal row per catalog of every installed addon (`board`).
///
/// `Load CatalogsWithExtra` only plans the catalogs; their first pages are
/// fetched by `LoadRange` for the rows on screen (plus overscan), re-issued
/// as the user scrolls whenever the requested range grows, like stremio-web.
/// The continue-watching row is never loaded or unloaded: the engine keeps
/// it in step with the library.
class BoardScreen extends StatefulWidget {
  const BoardScreen({super.key});

  /// Every row (continue watching included) has this extent, so the visible
  /// rows follow from the scroll offset alone.
  static double rowExtentFor(double width) => width >= 720 ? 260 : 200;

  /// Rows requested beyond the visible ones, on each side.
  static const int overscanRows = 1;

  /// How long scrolling must pause before the range is recomputed.
  static const Duration scrollDebounce = Duration(milliseconds: 200);

  /// Tiles shown per catalog row before the "See all" tile.
  static const int maxTilesPerRow = 30;

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _board;
  CoreFieldNotifier? _continueWatching;
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  /// The union of every `LoadRange` dispatched so far (inclusive), so the
  /// range only ever grows and never repeats.
  int? _requestedStart;
  int? _requestedEnd;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scheduleRangeUpdate);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _board?.removeListener(_onBoardChanged);
      _board?.dispose();
      _continueWatching?.dispose();
      _client = client;
      _board = CoreFieldNotifier(client, CoreField.board)
        ..addListener(_onBoardChanged);
      _continueWatching = CoreFieldNotifier(
        client,
        CoreField.continueWatchingPreview,
      );
      _requestedStart = null;
      _requestedEnd = null;
      client.dispatch(CoreActions.loadBoard());
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateRange());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _client?.dispatch(CoreActions.unload(CoreField.board));
    _board?.removeListener(_onBoardChanged);
    _board?.dispose();
    _continueWatching?.dispose();
    super.dispose();
  }

  /// New board state may add or drop rows under the same scroll offset.
  void _onBoardChanged() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateRange());

  void _scheduleRangeUpdate() {
    _debounce?.cancel();
    _debounce = Timer(BoardScreen.scrollDebounce, _updateRange);
  }

  CatalogsWithExtraState get _boardState =>
      CatalogsWithExtraState.fromJson(_board?.value ?? const {});

  ContinueWatchingState get _continueWatchingState =>
      ContinueWatchingState.fromJson(_continueWatching?.value ?? const {});

  /// The rows as laid out: continue watching first when it has items, then
  /// every catalog row that is not known to be empty.
  List<_BoardRow> _rows(
    CatalogsWithExtraState board,
    ContinueWatchingState continueWatching,
  ) => [
    if (!continueWatching.isEmpty) _ContinueWatchingRow(continueWatching),
    for (final row in board.visibleRows) _CatalogRow(row),
  ];

  /// Dispatches `LoadRange` for the catalogs whose rows are on screen (plus
  /// overscan) when that widens what has been requested so far.
  void _updateRange() {
    if (!mounted || _client == null) return;
    final extent = BoardScreen.rowExtentFor(MediaQuery.sizeOf(context).width);
    final position = _scroll.hasClients ? _scroll.position : null;
    final offset = position?.pixels ?? 0;
    final viewport =
        position?.viewportDimension ?? MediaQuery.sizeOf(context).height;
    final firstVisual = math.max(
      0,
      (offset / extent).floor() - BoardScreen.overscanRows,
    );
    final lastVisual =
        ((offset + viewport) / extent).ceil() - 1 + BoardScreen.overscanRows;

    final rows = _rows(_boardState, _continueWatchingState);
    int start;
    int end;
    if (rows.whereType<_CatalogRow>().isEmpty) {
      // Nothing planned yet (the Load has not come back): assume one catalog
      // per row so the first rows are requested as soon as they exist.
      start = firstVisual;
      end = lastVisual;
    } else {
      final visible = [
        for (var i = firstVisual; i <= lastVisual && i < rows.length; i++)
          if (rows[i] case _CatalogRow(:final row)) row.index,
      ];
      if (visible.isEmpty) return;
      start = visible.first;
      end = visible.last;
    }

    final nextStart = math.min(_requestedStart ?? start, start);
    final nextEnd = math.max(_requestedEnd ?? end, end);
    if (nextStart == _requestedStart && nextEnd == _requestedEnd) return;
    _requestedStart = nextStart;
    _requestedEnd = nextEnd;
    _client!.dispatch(CoreActions.loadBoardRange(nextStart, nextEnd));
  }

  void _openDetails(String type, String id, {String? videoId}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MetaDetailsScreen(type: type, id: id, videoId: videoId),
      ),
    );
  }

  void _openCatalog(CatalogRow row) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscoverScreen(request: row.firstRequest),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final extent = BoardScreen.rowExtentFor(MediaQuery.sizeOf(context).width);
    return Scaffold(
      appBar: AppBar(title: const Text('Board')),
      body: ListenableBuilder(
        listenable: Listenable.merge([_board!, _continueWatching!]),
        builder: (context, _) {
          if (_board!.value == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final board = _boardState;
          final rows = _rows(board, _continueWatchingState);
          if (rows.isEmpty) {
            if (!board.isLoaded || board.isLoading) {
              return const Center(child: CircularProgressIndicator());
            }
            return const _EmptyBoard();
          }
          return ListView.builder(
            key: const Key('board-rows'),
            controller: _scroll,
            itemExtent: extent,
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: rows.length,
            itemBuilder: (context, index) => switch (rows[index]) {
              _ContinueWatchingRow(:final state) => _ContinueWatchingRowView(
                state: state,
                extent: extent,
                onOpen: (item) =>
                    _openDetails(item.type, item.id, videoId: item.videoId),
              ),
              _CatalogRow(:final row) => _CatalogRowView(
                row: row,
                extent: extent,
                onOpen: (item) => _openDetails(item.type, item.id),
                onSeeAll: () => _openCatalog(row),
              ),
            },
          );
        },
      ),
    );
  }
}

sealed class _BoardRow {
  const _BoardRow();
}

final class _ContinueWatchingRow extends _BoardRow {
  const _ContinueWatchingRow(this.state);

  final ContinueWatchingState state;
}

final class _CatalogRow extends _BoardRow {
  const _CatalogRow(this.row);

  final CatalogRow row;
}

/// Shared geometry of one row: a header, then a horizontal strip whose tile
/// width follows from the strip height and the poster shape.
class _RowLayout {
  const _RowLayout(this.extent);

  final double extent;

  static const double headerHeight = 52;
  static const double bottomPadding = 8;
  static const EdgeInsets stripPadding = EdgeInsets.symmetric(horizontal: 16);
  static const double tileSpacing = 12;

  double get stripHeight => extent - headerHeight - bottomPadding;

  double get imageHeight => stripHeight - PosterTile.captionHeight;

  double tileWidthFor(String posterShape) =>
      (imageHeight * PosterImage.aspectRatioFor(posterShape)).roundToDouble();
}

class _RowHeader extends StatelessWidget {
  const _RowHeader({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: _RowLayout.headerHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ContinueWatchingRowView extends StatelessWidget {
  const _ContinueWatchingRowView({
    required this.state,
    required this.extent,
    required this.onOpen,
  });

  final ContinueWatchingState state;
  final double extent;
  final ValueChanged<LibraryItemView> onOpen;

  @override
  Widget build(BuildContext context) {
    final layout = _RowLayout(extent);
    return Column(
      children: [
        const _RowHeader(title: 'Continue watching'),
        Expanded(
          child: _HorizontalStrip(
            itemCount: state.items.length,
            itemBuilder: (context, index) {
              final item = state.items[index];
              return SizedBox(
                width: layout.tileWidthFor(item.posterShape),
                child: LibraryItemTile(
                  item: item,
                  onTap: () => onOpen(item),
                  showWatchedMark: false,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: _RowLayout.bottomPadding),
      ],
    );
  }
}

class _CatalogRowView extends StatelessWidget {
  const _CatalogRowView({
    required this.row,
    required this.extent,
    required this.onOpen,
    required this.onSeeAll,
  });

  final CatalogRow row;
  final double extent;
  final ValueChanged<MetaItemPreview> onOpen;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final layout = _RowLayout(extent);
    return Column(
      children: [
        _RowHeader(title: row.title, subtitle: row.subtitle),
        Expanded(child: _content(layout)),
        const SizedBox(height: _RowLayout.bottomPadding),
      ],
    );
  }

  Widget _content(_RowLayout layout) {
    final error = row.error;
    if (error != null) return _RowError(message: error.message);
    final items = row.items;
    if (items.isEmpty) {
      // Planned but outside the requested range, or still loading.
      return _PlaceholderStrip(
        tileWidth: layout.tileWidthFor(row.posterShape),
        imageHeight: layout.imageHeight,
      );
    }
    final shown = math.min(items.length, BoardScreen.maxTilesPerRow);
    final tileWidth = layout.tileWidthFor(row.posterShape);
    return _HorizontalStrip(
      itemCount: shown + 1,
      itemBuilder: (context, index) {
        if (index == shown) {
          return SizedBox(
            width: tileWidth,
            child: _SeeAllTile(onTap: onSeeAll),
          );
        }
        final item = items[index];
        return SizedBox(
          width: tileWidth,
          child: PosterTile(item: item, onTap: () => onOpen(item)),
        );
      },
    );
  }
}

/// The trailing tile of a catalog row: opens the whole catalog in Discover.
class _SeeAllTile extends StatelessWidget {
  const _SeeAllTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusableTile(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.arrow_forward,
                    color: theme.colorScheme.primary,
                    size: 28,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'See all',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: PosterTile.captionHeight),
        ],
      ),
    );
  }
}

/// Neutral boxes standing in for tiles that have not arrived.
class _PlaceholderStrip extends StatelessWidget {
  const _PlaceholderStrip({required this.tileWidth, required this.imageHeight});

  final double tileWidth;
  final double imageHeight;

  static const int count = 6;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      padding: _RowLayout.stripPadding,
      itemCount: count,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(right: _RowLayout.tileSpacing),
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: tileWidth,
            height: imageHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RowError extends StatelessWidget {
  const _RowError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: ListTile(
      dense: true,
      leading: const Icon(Icons.cloud_off_outlined),
      title: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
    ),
  );
}

/// A horizontal list of tiles with its own controller so desktop gets a
/// visible scrollbar (touch platforms keep the default fading one).
class _HorizontalStrip extends StatefulWidget {
  const _HorizontalStrip({required this.itemCount, required this.itemBuilder});

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<_HorizontalStrip> createState() => _HorizontalStripState();
}

class _HorizontalStripState extends State<_HorizontalStrip> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = switch (Theme.of(context).platform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };
    return Scrollbar(
      controller: _controller,
      thumbVisibility: isDesktop,
      child: ListView.builder(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: _RowLayout.stripPadding,
        itemCount: widget.itemCount,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.only(right: _RowLayout.tileSpacing),
          child: widget.itemBuilder(context, index),
        ),
      ),
    );
  }
}

class _EmptyBoard extends StatelessWidget {
  const _EmptyBoard();

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
              Icons.extension_off_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('No catalogs', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Install an addon with catalogs to fill the board.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AddonsScreen()),
              ),
              icon: const Icon(Icons.extension_outlined),
              label: const Text('Browse addons'),
            ),
          ],
        ),
      ),
    );
  }
}
