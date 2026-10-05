import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/tv_density.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/library_item_actions_sheet.dart';
import '../../widgets/library_item_tile.dart';
import '../../widgets/poster_tile.dart';
import '../addons/addons_screen.dart';
import '../addons/failed_addons.dart';
import '../details/meta_details_screen.dart';

/// Discover's rows: a "Continue watching" row, then one row per catalog
/// that can be asked with nothing chosen, of [type] or of every type
/// (`board`, a `CatalogsWithExtra`).
///
/// `Load CatalogsWithExtra` only plans the catalogs; their first pages are
/// fetched by `LoadRange` for the rows on screen (plus overscan), re-issued
/// as the user scrolls whenever the requested range grows, like stremio-web.
/// Changing [type] plans the rows again and starts them from the top. The
/// continue-watching row is never loaded or unloaded: the engine keeps it
/// in step with the library, and it follows [type] here.
class CatalogRows extends StatefulWidget {
  const CatalogRows({
    super.key,
    required this.onSeeAll,
    this.type,
    this.defaultFocus = false,
    this.empty,
  });

  /// The one type to show, or every type (null). The "Continue watching"
  /// row follows it too.
  final String? type;

  /// A row's "See all" was pressed.
  final ValueChanged<CatalogRow> onSeeAll;

  /// Whether the first tile takes the remote when nothing else has it --
  /// which it has at start-up, Discover being the screen the app opens on,
  /// and not when the tab is walked to from the rail, where the remote
  /// stays like on every other tab.
  final bool defaultFocus;

  /// Drawn where there are no rows at all, in place of the "install an
  /// addon" note.
  final Widget? empty;

  /// Every row (continue watching included) has this extent, so the visible
  /// rows follow from the scroll offset alone. A tile's width follows from
  /// it (the strip is what is left under the header, and the poster's shape
  /// turns that height into a width), so this is also how big the posters
  /// are.
  ///
  /// A television's is the other way round: the poster is
  /// [PosterTile.tvImageHeight], every television screen's one size, and
  /// the row is that and what goes round it -- which is what puts two whole
  /// rows on a Google TV's screen ([PosterTile.tvImageHeight] says how).
  static double rowExtentFor(double width, {bool isTv = false}) => isTv
      ? _RowLayout.tvBaseExtent
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
  State<CatalogRows> createState() => _CatalogRowsState();
}

class _CatalogRowsState extends State<CatalogRows> {
  CoreClient? _client;
  CoreFieldNotifier? _board;
  CoreFieldNotifier? _continueWatching;

  /// `ctx`, for the installed addons: a catalog that failed carries only
  /// the manifest URL it was asked at, and the profile is what turns that
  /// into an addon with a name that can be checked or uninstalled.
  ///
  /// Subscribed to only once a catalog has actually failed, by
  /// [_watchProfileForFailures]: `ctx` is the profile with its
  /// notifications and events, every event that touches it costs a
  /// serialize across FFI and a decode here, and the board stays mounted
  /// under the player while a film reports its progress.
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
      )..addListener(_onContinueWatchingChanged);
      _ctx = null;
      _requestedStart = null;
      _requestedEnd = null;
      client.dispatch(_loadAction());
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateRange());
    }
  }

  @override
  void didUpdateWidget(CatalogRows oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.type == widget.type) return;
    // Another type is another set of rows: planned again, requested again
    // from the first, and looked at from the top.
    _requestedStart = null;
    _requestedEnd = null;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _client?.dispatch(_loadAction());
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateRange());
  }

  CoreAction _loadAction() => CoreActions.loadBoard(type: widget.type);

  CoreAction _rangeAction(int start, int end) =>
      CoreActions.loadBoardRange(start, end);

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _client?.dispatch(CoreActions.unload(CoreField.board));
    _board?.removeListener(_onBoardChanged);
    _board?.dispose();
    _continueWatching?.dispose();
    _ctx?.dispose();
    _boardFocus.dispose();
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
    _debounce = Timer(CatalogRows.scrollDebounce, _updateRange);
  }

  /// Each read below is one parse per change of its field, however many
  /// times a build asks.
  final _boardParse = ParsedField(CatalogsWithExtraState.fromJson);
  final _continueWatchingParse = ParsedField(ContinueWatchingState.fromJson);
  final _profileParse = ParsedField(ProfileState.fromCtx);

  CatalogsWithExtraState get _boardState =>
      _boardParse.of(_board?.value ?? const {});

  ContinueWatchingState get _continueWatchingState =>
      _continueWatchingParse.of(_continueWatching?.value ?? const {});

  /// The profile behind `ctx`; null until its first pull comes back.
  ProfileState? get _profile {
    final ctx = _ctx?.value;
    return ctx == null ? null : _profileParse.of(ctx);
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
  ) {
    final type = widget.type;
    final watching = [
      for (final item in continueWatching.items)
        if (type == null || item.type == type) item,
    ];
    return [
      if (watching.isNotEmpty) _ContinueWatchingRow(watching),
      for (final row in board.visibleRows) _CatalogRow(row),
    ];
  }

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
      (offset / extent).floor() - CatalogRows.overscanRows,
    );
    final lastVisual =
        ((offset + viewport) / extent).ceil() - 1 + CatalogRows.overscanRows;

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
    _client!.dispatch(_rangeAction(nextStart, nextEnd));
  }

  void _openDetails(
    String type,
    String id, {
    String? videoId,
    DetailsOpenedFrom openedFrom = DetailsOpenedFrom.elsewhere,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MetaDetailsScreen(
          type: type,
          id: id,
          videoId: videoId,
          openedFrom: openedFrom,
        ),
      ),
    );
  }

  /// Above every tile of the board, so a lost remote can be put back on
  /// one of them ([_refocusAfterRemoval]). Not focusable itself.
  final FocusNode _boardFocus = FocusNode(
    debugLabel: 'board',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// A Continue-watching tile the remote was on has just been taken off
  /// the row: its id, and where it was on screen. Null otherwise.
  ({String id, Rect at})? _removed;

  Future<void> _continueWatchingLongPress(LibraryItemView item) async {
    final focused = FocusManager.instance.primaryFocus;
    final at = _boardFocus.hasFocus ? focused?.rect : null;
    final removed = await showContinueWatchingActions(context, _client, item);
    if (!removed || at == null || !mounted) return;
    _removed = (id: item.id, at: at);
    _onContinueWatchingChanged();
  }

  /// Once the row no longer has the title the remote was on, the remote
  /// goes to the tile nearest where it was.
  void _onContinueWatchingChanged() {
    final removed = _removed;
    if (removed == null ||
        _continueWatchingState.items.any((item) => item.id == removed.id)) {
      return;
    }
    _removed = null;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _refocusAfterRemoval(removed.at),
    );
  }

  /// Puts the remote on the board's tile nearest [at], if it was left on
  /// nothing.
  ///
  /// A strip's tiles are not keyed, so a tile taken out of the middle of
  /// the row hands its place, and the remote with it, to the one after it,
  /// and nothing needs doing. The last tile of a row has no one after it,
  /// and the row's only tile takes the row with it; there the remote would
  /// be left on the tab's bare scope, with no ring anywhere. Nearest is
  /// the tile before it in the row, or, with the row gone, the tile of the
  /// row that moved up into its place.
  void _refocusAfterRemoval(Rect at) {
    if (!mounted || _boardFocus.hasFocus) return;
    FocusNode? nearest;
    var best = double.infinity;
    for (final node in _boardFocus.traversalDescendants) {
      if (!node.canRequestFocus || node.context == null) continue;
      final distance = (node.rect.center - at.center).distance;
      if (distance < best) {
        best = distance;
        nearest = node;
      }
    }
    nearest?.requestFocus();
  }

  @override
  Widget build(BuildContext context) => _body(_RowLayout.of(context));

  Widget _body(_RowLayout layout) => ListenableBuilder(
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
        return widget.empty ?? const _EmptyBoard();
      }
      final isTv = DeviceScope.isTv(context);
      final rowsView = CustomScrollView(
        key: const Key('board-rows'),
        controller: _scroll,
        // On a television a row's strip is wider than the board, out to
        // the edge of the screen ([_WiderBy]), so this does not clip: the
        // board's clip is [_BleedRight], round all of it.
        clipBehavior: isTv ? Clip.none : Clip.hardEdge,
        slivers: [
          // Every row has the same extent, which is what lets the
          // requested range be read off the scroll offset alone.
          SliverFixedExtentList.builder(
            itemExtent: layout.extent,
            itemCount: rows.length,
            itemBuilder: (context, index) => switch (rows[index]) {
              _ContinueWatchingRow(:final items) => _ContinueWatchingRowView(
                items: items,
                layout: layout,
                isFirstRow: widget.defaultFocus && index == 0,
                onOpen: (item) => _openDetails(
                  item.type,
                  item.id,
                  videoId: item.videoId,
                  openedFrom: DetailsOpenedFrom.continueWatching,
                ),
                onLongPress: (item) =>
                    unawaited(_continueWatchingLongPress(item)),
              ),
              _CatalogRow(:final row) => _CatalogRowView(
                row: row,
                layout: layout,
                isFirstRow: widget.defaultFocus && index == 0,
                onOpen: (item) => _openDetails(item.type, item.id),
                onSeeAll: () => widget.onSeeAll(row),
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
                summaryLabel: CatalogRows.failedCatalogsLabel(
                  board.failedRows.length,
                ),
                collapseSingle: true,
                locked: _profile?.addonsLocked ?? false,
                onCheck: (failure) =>
                    openAddonDetails(context, failure.transportUrl),
                onUninstall: (failure) =>
                    confirmAndUninstallAddon(context, _client, failure.addon!),
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      );
      final focusable = Focus(focusNode: _boardFocus, child: rowsView);
      return isTv ? _BleedRight(child: focusable) : focusable;
    },
  );
}

/// One row of [PosterRows]: a heading over posters.
@immutable
class PosterRow {
  const PosterRow({
    required this.title,
    required this.items,
    this.subtitle,
    this.posterShape = 'poster',
  });

  final String title;
  final String? subtitle;
  final List<MetaItemPreview> items;

  /// The `posterShape` the row's catalog declares, which sets the tiles'
  /// width ([PosterImage.aspectRatioFor]).
  final String posterShape;
}

/// Rows of posters in Discover's geometry -- the same extent, heading,
/// tiles and focus room, and on a television the same run into the band at
/// the right -- for a screen whose rows are already in hand rather than
/// planned and fetched as the board's are: Search's hits, on a television.
///
/// [before] and [after] are slivers drawn above and below the rows, in the
/// same scroll.
class PosterRows extends StatelessWidget {
  const PosterRows({
    super.key,
    required this.rows,
    required this.onOpen,
    this.before = const [],
    this.after = const [],
  });

  final List<PosterRow> rows;
  final ValueChanged<MetaItemPreview> onOpen;
  final List<Widget> before;
  final List<Widget> after;

  @override
  Widget build(BuildContext context) {
    final layout = _RowLayout.of(context);
    final isTv = DeviceScope.isTv(context);
    final view = CustomScrollView(
      // As the board's: the strips reach the band, and [_BleedRight] is
      // the clip.
      clipBehavior: isTv ? Clip.none : Clip.hardEdge,
      slivers: [
        ...before,
        SliverFixedExtentList.builder(
          itemExtent: layout.extent,
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            final tileWidth = layout.tileWidthFor(row.posterShape);
            return Column(
              children: [
                _RowHeader(
                  title: row.title,
                  subtitle: row.subtitle,
                  height: layout.headerHeight,
                  inline: layout.inlineHeader,
                ),
                Expanded(
                  child: _HorizontalStrip(
                    padding: layout.stripPadding,
                    itemCount: row.items.length,
                    itemBuilder: (context, index) {
                      final item = row.items[index];
                      return SizedBox(
                        width: tileWidth,
                        child: PosterTile(
                          item: item,
                          onTap: () => onOpen(item),
                        ),
                      );
                    },
                  ),
                ),
                SizedBox(height: layout.bottomPadding),
              ],
            );
          },
        ),
        ...after,
        const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
      ],
    );
    return isTv ? _BleedRight(child: view) : view;
  }
}

/// [child] clipped to its own box, except at the right, where it may paint
/// on to the edge of the screen: through the television's overscan band,
/// which the shell keeps clear of every control but which a row of posters
/// runs on under, the way it would off the edge of any TV screen.
///
/// A row's strip is [widthIn] wider than the board for that ([_WiderBy]),
/// and as much longer at its end, so a poster the band crops loses some
/// picture and nothing else: a focused tile is scrolled to the middle of
/// the strip ([FocusableTile]), and the last one in a row, which cannot be,
/// still stops short of the band.
class _BleedRight extends StatelessWidget {
  const _BleedRight({required this.child});

  final Widget child;

  /// How far the board's right edge is from the screen's: the band,
  /// [TvDensity.overscan] of the screen. The board reaches the shell's
  /// safe area on that side, and the shell is all that keeps out of it.
  static double widthIn(BuildContext context) =>
      TvDensity.overscanPadding(MediaQuery.sizeOf(context)).right;

  @override
  Widget build(BuildContext context) =>
      ClipRect(clipper: _RightBleedClipper(widthIn(context)), child: child);
}

/// [child] laid out [extra] wider than the box it is given, out past the
/// box's right edge: the strip a row scrolls in, reaching the edge of the
/// screen ([_BleedRight]).
class _WiderBy extends StatelessWidget {
  const _WiderBy(this.extra, {required this.child});

  final double extra;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => OverflowBox(
      alignment: AlignmentDirectional.centerStart,
      minWidth: constraints.maxWidth + extra,
      maxWidth: constraints.maxWidth + extra,
      child: child,
    ),
  );
}

class _RightBleedClipper extends CustomClipper<Rect> {
  const _RightBleedClipper(this.bleed);

  final double bleed;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, 0, size.width + bleed, size.height);

  @override
  bool shouldReclip(_RightBleedClipper oldClipper) => oldClipper.bleed != bleed;
}

sealed class _BoardRow {
  const _BoardRow();
}

final class _ContinueWatchingRow extends _BoardRow {
  const _ContinueWatchingRow(this.items);

  /// The row's items: every one, or only those of the type being shown.
  final List<LibraryItemView> items;
}

final class _CatalogRow extends _BoardRow {
  const _CatalogRow(this.row);

  final CatalogRow row;
}

/// Shared geometry of one row: a header, then a horizontal strip whose tile
/// width follows from the strip height and the poster shape.
class _RowLayout {
  const _RowLayout(
    this.baseExtent, {
    this.textFactor = 1,
    this.focusSlack = 0,
    this.inlineHeader = false,
  });

  /// The row's height at text scale 1: what [CatalogRows.rowExtentFor]
  /// picked for this window.
  final double baseExtent;

  /// [TvDensity.textFactorOf], never below 1. The header and the caption
  /// are text in boxes of a fixed height, so both boxes grow with it -- and
  /// so does the row, rather than the strip between them shrinking.
  ///
  /// Never below 1: the boxes are an exact fit at scale 1 (52 dp of header
  /// is 12 of padding around 40 of title and subtitle), and the padding is
  /// fixed, so shrinking the box for a smaller system font -- Android's
  /// "Small" is 0.85, and a GTK text-scaling-factor goes under 1 too --
  /// overflows the text out of it. A small font just leaves the row roomy.
  final double textFactor;

  /// Room kept above and below the tiles in a strip, out of the strip's own
  /// height, for a focused tile to grow into.
  ///
  /// A strip clips to its own bounds and lays a tile out to exactly the
  /// viewport's height, so without this room the zoom a focused tile wears
  /// ([FocusHighlight.focusedScale]) and the shadow it casts would be cut
  /// off at both edges, reading as a crop rather than the lift it is meant
  /// to be. Only a television zooms anything, so only a television spends
  /// poster height on the room.
  final double focusSlack;

  /// The header is one line, the catalog's subtitle after its title rather
  /// than under it, and the rows have no gap of their own between them (the
  /// strip's [focusSlack] and the header's padding are gap enough): a
  /// television's, whose rows share the screen two at a time, and for
  /// which these are height off the poster.
  final bool inlineHeader;

  /// The row geometry [context] is in.
  static _RowLayout of(BuildContext context) {
    final isTv = DeviceScope.isTv(context);
    return _RowLayout(
      CatalogRows.rowExtentFor(MediaQuery.sizeOf(context).width, isTv: isTv),
      textFactor: math.max(1, TvDensity.textFactorOf(context)),
      focusSlack: isTv ? focusRoom : 0,
      inlineHeader: isTv,
    );
  }

  static const double tallHeaderHeight = 52;

  /// [tallHeaderHeight] for a header of one line ([inlineHeader]): 8 of
  /// padding above and 4 below the 24 of a title.
  static const double inlineHeaderHeight = 36;

  static const double rowGap = 8;

  /// A television's row at text scale 1: a [PosterTile.tvImageHeight]
  /// poster and everything round it -- the one-line header, the room a
  /// focused tile grows into above and below, and the caption's box and
  /// inset.
  static const double tvBaseExtent =
      inlineHeaderHeight +
      focusRoom * 2 +
      PosterTile.captionInset +
      PosterTile.captionHeight +
      PosterTile.tvImageHeight;
  static const double stripSidePadding = 16;
  static const double tileSpacing = 12;

  /// [focusSlack] on a television: half of it covers the zoom (five percent
  /// of a tile that tall, split between the two edges) and the rest is what
  /// the shadow under a focused tile needs to be seen at all.
  static const double focusRoom = 12;

  /// What a strip insets its tiles by: the side margin, and [focusSlack]
  /// above and below.
  EdgeInsets get stripPadding =>
      EdgeInsets.symmetric(horizontal: stripSidePadding, vertical: focusSlack);

  /// What the list scrolls by: [baseExtent] plus exactly the room the two
  /// text boxes gained. The poster between them therefore keeps the same
  /// height at every text scale, instead of being squeezed -- without this,
  /// past a 2.1x text scale the height goes negative, which is a
  /// `NOT NORMALIZED` constraints failure, not just a cramped layout.
  double get extent =>
      baseExtent +
      (baseHeaderHeight + PosterTile.captionHeight) * (textFactor - 1);

  double get baseHeaderHeight =>
      inlineHeader ? inlineHeaderHeight : tallHeaderHeight;

  double get bottomPadding => inlineHeader ? 0 : rowGap;

  double get headerHeight => baseHeaderHeight * textFactor;

  double get stripHeight => extent - headerHeight - bottomPadding;

  /// The poster's box: the strip less the room a focused tile grows into,
  /// the caption's own box, and the inset that keeps the ring off the
  /// words ([PosterTile.captionInset], which is a constant and so is not
  /// scaled with the text the way the caption box is).
  double get imageHeight =>
      stripHeight -
      focusSlack * 2 -
      PosterTile.captionInset -
      PosterTile.captionHeight * textFactor;

  double tileWidthFor(String posterShape) =>
      (imageHeight * PosterImage.aspectRatioFor(posterShape)).roundToDouble();
}

class _RowHeader extends StatelessWidget {
  const _RowHeader({
    required this.title,
    required this.height,
    this.subtitle,
    this.inline = false,
  });

  final String title;

  /// [_RowLayout.headerHeight]: the row's geometry decides it, since what
  /// is left over is the strip.
  final double height;

  final String? subtitle;

  /// [_RowLayout.inlineHeader]: the subtitle on the title's line.
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = this.subtitle;
    final hasSubtitle = subtitle != null && subtitle.isNotEmpty;
    final subtitleStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: inline
            ? Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text.rich(
                  TextSpan(
                    text: title,
                    style: theme.textTheme.titleMedium,
                    children: [
                      if (hasSubtitle)
                        TextSpan(text: '   $subtitle', style: subtitleStyle),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  if (hasSubtitle)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: subtitleStyle,
                    ),
                ],
              ),
      ),
    );
  }
}

class _ContinueWatchingRowView extends StatelessWidget {
  const _ContinueWatchingRowView({
    required this.items,
    required this.layout,
    required this.isFirstRow,
    required this.onOpen,
    required this.onLongPress,
  });

  final List<LibraryItemView> items;
  final _RowLayout layout;

  /// The row's first tile is where TV focus starts on a fresh Board.
  final bool isFirstRow;

  final ValueChanged<LibraryItemView> onOpen;

  /// The long-press menu ([showContinueWatchingActions]): a title never
  /// added to the library has no other way off this row (today's
  /// workaround was add to library, Rewind, remove from library).
  final ValueChanged<LibraryItemView> onLongPress;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _RowHeader(
          title: 'Continue watching',
          height: layout.headerHeight,
          inline: layout.inlineHeader,
        ),
        Expanded(
          child: _HorizontalStrip(
            padding: layout.stripPadding,
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                width: layout.tileWidthFor(item.posterShape),
                child: LibraryItemTile(
                  item: item,
                  onTap: () => onOpen(item),
                  onLongPress: () => onLongPress(item),
                  showWatchedMark: false,
                  memoryId: 'continue-watching/${item.id}',
                  defaultFocus: isFirstRow && index == 0,
                ),
              );
            },
          ),
        ),
        SizedBox(height: layout.bottomPadding),
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
          inline: layout.inlineHeader,
        ),
        Expanded(child: _content(layout)),
        SizedBox(height: layout.bottomPadding),
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
        padding: layout.stripPadding,
      );
    }
    final shown = math.min(items.length, CatalogRows.maxTilesPerRow);
    final tileWidth = layout.tileWidthFor(row.posterShape);
    return _HorizontalStrip(
      padding: layout.stripPadding,
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
          // Stands in for a tile's caption, so this box lines up with the
          // posters beside it: the inset below their words is part of it.
          const SizedBox(
            height: PosterTile.captionHeight + PosterTile.captionInset,
          ),
        ],
      ),
    );
  }
}

/// Neutral boxes standing in for tiles that have not arrived.
class _PlaceholderStrip extends StatelessWidget {
  const _PlaceholderStrip({
    required this.tileWidth,
    required this.imageHeight,
    required this.padding,
  });

  final double tileWidth;
  final double imageHeight;

  /// [_RowLayout.stripPadding], as the real strip beside it uses.
  final EdgeInsets padding;

  static const int count = 6;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    final bleed = DeviceScope.isTv(context)
        ? _BleedRight.widthIn(context)
        : 0.0;
    final list = ListView.builder(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      padding: padding + EdgeInsets.only(right: bleed),
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
    return bleed > 0 ? _WiderBy(bleed, child: list) : list;
  }
}

/// A horizontal list of tiles with its own controller so desktop gets a
/// visible scrollbar (touch platforms keep the default fading one).
///
/// A television gets none at all: a thumb is there to be dragged, and a
/// remote has nothing to drag it with -- the row scrolls when focus moves
/// off its end, which is the only way it ever scrolls there.
class _HorizontalStrip extends StatefulWidget {
  const _HorizontalStrip({
    required this.itemCount,
    required this.itemBuilder,
    required this.padding,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// [_RowLayout.stripPadding]: the side margin, and the room a focused
  /// tile grows into rather than being clipped by the viewport's edge.
  final EdgeInsets padding;

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
    final isTv = DeviceScope.isTv(context);
    final bleed = isTv ? _BleedRight.widthIn(context) : 0.0;
    final list = ListView.builder(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      padding: widget.padding + EdgeInsets.only(right: bleed),
      itemCount: widget.itemCount,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(right: _RowLayout.tileSpacing),
        child: widget.itemBuilder(context, index),
      ),
    );
    if (isTv) return _WiderBy(bleed, child: list);
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
