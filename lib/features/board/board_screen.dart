import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/library_item_tile.dart';
import '../../widgets/poster_tile.dart';
import '../addons/addons_screen.dart';
import '../addons/failed_addons.dart';
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
  /// rows follow from the scroll offset alone. A tile's width follows from
  /// it (the strip is what is left under the header, and the poster's shape
  /// turns that height into a width), so this is also how big the posters
  /// are: on a television they are read from across the room, and a 1080p
  /// set has the pixels to spare.
  static double rowExtentFor(double width, {bool isTv = false}) => isTv
      ? 360
      : width >= 720
      ? 260
      : 200;

  /// Rows requested beyond the visible ones, on each side.
  static const int overscanRows = 1;

  /// How long scrolling must pause before the range is recomputed.
  static const Duration scrollDebounce = Duration(milliseconds: 200);

  /// Tiles shown per catalog row before the "See all" tile.
  static const int maxTilesPerRow = 30;

  /// The line under the rows for the catalogs that were dropped. It counts
  /// catalogs, not addons: a catalog is what the viewer expected to see,
  /// and one dead addon can take several of them down at once.
  static String failedCatalogsLabel(int count) => count == 1
      ? '1 catalog could not be loaded'
      : '$count catalogs could not be loaded';

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _board;
  CoreFieldNotifier? _continueWatching;

  /// `ctx`, for the installed addons: a catalog that failed carries only
  /// the manifest URL it was asked at, and the profile is what turns that
  /// into an addon with a name that can be checked or uninstalled.
  ///
  /// Subscribed to only once a catalog has actually failed, by
  /// [_watchProfileForFailures]: `ctx` is the whole context -- the library
  /// included -- so every event that touches it costs a serialize across
  /// FFI and a decode here, and the board stays mounted under the player
  /// while a film reports its progress.
  CoreFieldNotifier? _ctx;
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
      _ctx?.dispose();
      _client = client;
      _board = CoreFieldNotifier(client, CoreField.board)
        ..addListener(_onBoardChanged);
      _continueWatching = CoreFieldNotifier(
        client,
        CoreField.continueWatchingPreview,
      );
      _ctx = null;
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
    _ctx?.dispose();
    super.dispose();
  }

  /// New board state may add or drop rows under the same scroll offset,
  /// and may be the first state with an addon to name.
  void _onBoardChanged() {
    _watchProfileForFailures();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateRange());
  }

  /// Starts pulling `ctx` the first time a catalog fails, and keeps it from
  /// then on: a profile that has one dead addon usually keeps it, and the
  /// names would otherwise arrive a frame after each new failure.
  void _watchProfileForFailures() {
    final client = _client;
    if (_ctx != null || client == null || _boardState.failedRows.isEmpty) {
      return;
    }
    setState(() => _ctx = CoreFieldNotifier(client, CoreField.ctx));
  }

  void _scheduleRangeUpdate() {
    _debounce?.cancel();
    _debounce = Timer(BoardScreen.scrollDebounce, _updateRange);
  }

  CatalogsWithExtraState get _boardState =>
      CatalogsWithExtraState.fromJson(_board?.value ?? const {});

  ContinueWatchingState get _continueWatchingState =>
      ContinueWatchingState.fromJson(_continueWatching?.value ?? const {});

  /// The profile behind `ctx`; null until its first pull comes back.
  ProfileState? get _profile {
    final ctx = _ctx?.value;
    return ctx == null ? null : ProfileState.fromCtx(ctx);
  }

  /// The addons behind the rows that were dropped, one card's worth each.
  /// The count the summary line reports is still catalogs — that is what
  /// went missing — even where two of them are one card.
  List<AddonFailure> _failures(CatalogsWithExtraState board) =>
      addonFailuresOf(board.failedRows, _profile);

  /// The rows as laid out: continue watching first when it has items, then
  /// every catalog row that has something to show — the ones the addon
  /// answered empty and the ones it could not answer at all are both left
  /// out.
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
    final extent = _RowLayout.of(context).extent;
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
    if (_boardState.rows.isEmpty) {
      // Nothing planned yet (the Load has not come back): assume one catalog
      // per row so the first rows are requested as soon as they exist.
      start = firstVisual;
      end = lastVisual;
    } else {
      final visible = [
        for (var i = firstVisual; i <= lastVisual && i < rows.length; i++)
          if (rows[i] case _CatalogRow(:final row)) row.index,
      ];
      // Planned, but no catalog is on screen -- every one of them failed,
      // and what is scrolling is the account of that. Those offsets are
      // card heights, so no catalog index can be read off them.
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
    final layout = _RowLayout.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Board')),
      body: ListenableBuilder(
        listenable: Listenable.merge([_board!, _continueWatching!, _ctx]),
        builder: (context, _) {
          if (_board!.value == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final board = _boardState;
          final rows = _rows(board, _continueWatchingState);
          final failures = _failures(board);
          if (rows.isEmpty && failures.isEmpty) {
            if (!board.isLoaded || board.isLoading) {
              return const Center(child: CircularProgressIndicator());
            }
            return const _EmptyBoard();
          }
          return CustomScrollView(
            key: const Key('board-rows'),
            controller: _scroll,
            slivers: [
              // Every row has the same extent, which is what lets the
              // requested range be read off the scroll offset alone.
              SliverFixedExtentList.builder(
                itemExtent: layout.extent,
                itemCount: rows.length,
                itemBuilder: (context, index) => switch (rows[index]) {
                  _ContinueWatchingRow(:final state) =>
                    _ContinueWatchingRowView(
                      state: state,
                      layout: layout,
                      isFirstRow: index == 0,
                      onOpen: (item) => _openDetails(
                        item.type,
                        item.id,
                        videoId: item.videoId,
                      ),
                    ),
                  _CatalogRow(:final row) => _CatalogRowView(
                    row: row,
                    layout: layout,
                    isFirstRow: index == 0,
                    onOpen: (item) => _openDetails(item.type, item.id),
                    onSeeAll: () => _openCatalog(row),
                  ),
                },
              ),
              // What the rows above do not account for, once, at the end:
              // a catalog that simply vanished is a bug report nobody can
              // write, and the board is where the loss is noticed.
              if (failures.isNotEmpty)
                SliverToBoxAdapter(
                  child: FailedAddonsSection(
                    failures: failures,
                    summaryLabel: BoardScreen.failedCatalogsLabel(
                      board.failedRows.length,
                    ),
                    collapseSingle: true,
                    locked: _profile?.addonsLocked ?? false,
                    onCheck: (failure) =>
                        openAddonDetails(context, failure.transportUrl),
                    onUninstall: (failure) => confirmAndUninstallAddon(
                      context,
                      _client,
                      failure.addon!,
                    ),
                  ),
                ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
            ],
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
  const _RowLayout(this.baseExtent, {this.textFactor = 1});

  /// The row's height at text scale 1: what [BoardScreen.rowExtentFor]
  /// picked for this window.
  final double baseExtent;

  /// How much bigger text is here than at the size these constants were
  /// picked for: a television scales it up, and so does a system-wide
  /// accessibility setting anywhere. The header and the caption are text in
  /// boxes of a fixed height, so both boxes grow with it -- and so does the
  /// row, rather than the strip between them shrinking.
  ///
  /// Never below 1: the boxes are an exact fit at scale 1 (52 dp of header
  /// is 12 of padding around 40 of title and subtitle), and the padding is
  /// fixed, so shrinking the box for a smaller system font -- Android's
  /// "Small" is 0.85, and a GTK text-scaling-factor goes under 1 too --
  /// overflows the text out of it. A small font just leaves the row roomy.
  final double textFactor;

  /// The row geometry [context] is in.
  static _RowLayout of(BuildContext context) => _RowLayout(
    BoardScreen.rowExtentFor(
      MediaQuery.sizeOf(context).width,
      isTv: DeviceScope.isTv(context),
    ),
    textFactor: math.max(1, textFactorOf(context)),
  );

  static const double baseHeaderHeight = 52;
  static const double bottomPadding = 8;
  static const EdgeInsets stripPadding = EdgeInsets.symmetric(horizontal: 16);
  static const double tileSpacing = 12;

  /// The size the scale is probed at: about what the header's title and a
  /// poster's caption are set in, and small enough to sit in the part of
  /// the curve that actually moves.
  static const double probeFontSize = 16;

  /// The text scale in play here, as a plain factor.
  ///
  /// Probed at [probeFontSize] rather than at some large round number,
  /// because a [TextScaler] need not be linear: Android 14 and later scale
  /// fonts through a lookup table that lifts body sizes hard and then
  /// flattens out, and AOSP's tables are anchored so that 100sp maps to
  /// 100dp at *every* font setting. A probe at 100 therefore comes back
  /// 1.0 however large the viewer asked for their text, while the 16sp
  /// header is being drawn nearly twice the size.
  static double textFactorOf(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(probeFontSize) / probeFontSize;

  /// What the list scrolls by: [baseExtent] plus exactly the room the two
  /// text boxes gained. The poster between them therefore keeps the same
  /// height at every text scale, instead of being squeezed -- past 2.1x it
  /// used to go negative, and a negative box is not a cramped layout but a
  /// `NOT NORMALIZED` constraints failure.
  double get extent =>
      baseExtent +
      (baseHeaderHeight + PosterTile.captionHeight) * (textFactor - 1);

  double get headerHeight => baseHeaderHeight * textFactor;

  double get stripHeight => extent - headerHeight - bottomPadding;

  double get imageHeight => stripHeight - PosterTile.captionHeight * textFactor;

  double tileWidthFor(String posterShape) =>
      (imageHeight * PosterImage.aspectRatioFor(posterShape)).roundToDouble();
}

class _RowHeader extends StatelessWidget {
  const _RowHeader({required this.title, required this.height, this.subtitle});

  final String title;

  /// [_RowLayout.headerHeight]: the row's geometry decides it, since what
  /// is left over is the strip.
  final double height;

  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
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
    required this.layout,
    required this.isFirstRow,
    required this.onOpen,
  });

  final ContinueWatchingState state;
  final _RowLayout layout;

  /// The row's first tile is where TV focus starts on a fresh Board.
  final bool isFirstRow;

  final ValueChanged<LibraryItemView> onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _RowHeader(title: 'Continue watching', height: layout.headerHeight),
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
                  memoryId: 'continue-watching/${item.id}',
                  defaultFocus: isFirstRow && index == 0,
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
    required this.layout,
    required this.isFirstRow,
    required this.onOpen,
    required this.onSeeAll,
  });

  final CatalogRow row;
  final _RowLayout layout;

  /// The row's first tile is where TV focus starts on a fresh Board.
  final bool isFirstRow;

  final ValueChanged<MetaItemPreview> onOpen;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _RowHeader(
          title: row.title,
          subtitle: row.subtitle,
          height: layout.headerHeight,
        ),
        Expanded(child: _content(layout)),
        const SizedBox(height: _RowLayout.bottomPadding),
      ],
    );
  }

  Widget _content(_RowLayout layout) {
    // A row that failed never reaches here: `visibleRows` drops it, and the
    // board accounts for it once at the end instead.
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
            child: _SeeAllTile(
              onTap: onSeeAll,
              memoryId: 'catalog/${row.index}/see-all',
            ),
          );
        }
        final item = items[index];
        return SizedBox(
          width: tileWidth,
          child: PosterTile(
            item: item,
            onTap: () => onOpen(item),
            memoryId: 'catalog/${row.index}/${item.id}',
            defaultFocus: isFirstRow && index == 0,
          ),
        );
      },
    );
  }
}

/// The trailing tile of a catalog row: opens the whole catalog in Discover.
class _SeeAllTile extends StatelessWidget {
  const _SeeAllTile({required this.onTap, required this.memoryId});

  final VoidCallback onTap;
  final String memoryId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusableTile(
      onTap: onTap,
      memoryId: memoryId,
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

/// A horizontal list of tiles with its own controller so desktop gets a
/// visible scrollbar (touch platforms keep the default fading one).
///
/// A television gets none at all: a thumb is there to be dragged, and a
/// remote has nothing to drag it with -- the row scrolls when focus moves
/// off its end, which is the only way it ever scrolls there.
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
    final list = ListView.builder(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      padding: _RowLayout.stripPadding,
      itemCount: widget.itemCount,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(right: _RowLayout.tileSpacing),
        child: widget.itemBuilder(context, index),
      ),
    );
    if (DeviceScope.isTv(context)) return list;
    return Scrollbar(
      controller: _controller,
      thumbVisibility: isDesktop,
      child: list,
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
