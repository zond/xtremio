import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/tv_density.dart';
import '../../widgets/content_type_label.dart';
import '../../widgets/filter_controls.dart';
import '../../widgets/poster_tile.dart';
import '../../widgets/shared_field_screen.dart';
import '../../widgets/tv_ladder.dart';
import '../details/meta_details_screen.dart';
import 'catalog_rows.dart';
import 'discover_catalogs.dart';

/// Browses the catalogs of the installed addons: all of them as rows, one
/// type's as rows, or one catalog with its filters as a grid.
///
/// **The tab** ([request] null) is the screen the app opens on: every
/// catalog's first page as a row ([CatalogRows], on [CoreField.board]),
/// under a "Continue watching" row. Across the top are
/// the types, starting with All; choosing one shows the rows of that type.
/// A type other than All adds a catalog menu, on "Any" -- the rows -- and
/// choosing a catalog there, or "See all" on a row, opens that catalog as
/// a grid with its filters beside the menu. Back comes down the same way:
/// the catalog to its type's rows, a type's rows to All. The rows stay
/// built under the grid, so coming back finds them where they were.
///
/// **A Discover pushed with a [request]** (a genre chip on a title) opens
/// straight on that catalog and
/// stays a catalog view: its types and catalogs are the engine's own, and
/// it never shows rows -- the rows' field is the tab's, and a second screen
/// loading it would empty the tab's rows when it left.
///
/// The catalog is `Load CatalogWithFilters` on the shared `discover`
/// field. The engine answers with `selectable` (the catalog's filters, the
/// types and catalogs around it), where every entry carries the request
/// that selects it; choosing one dispatches that request verbatim. The
/// pages are a poster grid that loads the next page near the end of the
/// scroll. The field is unloaded when the catalog view goes, unless
/// another Discover screen has loaded it since.
///
/// On a TV the header and the content are separate [FocusTraversalGroup]s,
/// the tab's header two rungs of a [TvLadder] (types, then menus), and the
/// posters remember which one had focus for the shell's per-tab memory. A Discover pushed on top of another screen puts focus on its
/// first poster, since nothing else on it holds any; the Discover tab does
/// not, so selecting the tab keeps focus on the rail like the other tabs.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, this.request});

  /// The catalog to open, for a Discover pushed over another screen; null
  /// is the tab, which opens on the rows.
  final ResourceRequest? request;

  /// What the rows say for a type whose every catalog needs a choice made
  /// first -- a genre, say -- so none of them can be a row.
  static const String noRowsLabel =
      'Every catalog of this type needs a choice first. Pick one from the '
      'Catalog menu.';

  /// The catalog menu's entry for the rows.
  static const String anyCatalogLabel = 'Any';

  /// The type chip for every type.
  static const String allTypesLabel = 'All';

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

/// Two of these screens can be on the stack at once (the Discover tab, a
/// poster, its details, a genre chip), both on the one `discover` field: see
/// [SharedFieldScreen].
class _DiscoverScreenState extends State<DiscoverScreen>
    with SharedFieldScreen<DiscoverScreen, DiscoverState> {
  CoreClient? _client;
  CoreFieldNotifier? _discover;

  /// The profile, for one thing only: what the addon behind a catalog is
  /// called, so the catalog menu can gather its entries under it.
  CoreFieldNotifier? _ctx;
  int _nextPageRequestedAt = -1;

  /// The catalog on screen: the one the last `Load` asked for, which names
  /// this screen's states. Null while the tab shows rows.
  ResourceRequest? _request;

  /// The type the tab's rows (and catalog menu) are of; null is All.
  String? _type;

  /// The tab, which browses; a pushed Discover only ever shows a catalog.
  bool get _browses => widget.request == null;

  bool get _showsCatalog => _request != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _discover?.dispose();
      _ctx?.dispose();
      _client = client;
      _discover = CoreFieldNotifier(client, CoreField.discover)
        ..addListener(onFieldChanged);
      _ctx = CoreFieldNotifier(client, CoreField.ctx);
      final request = widget.request;
      if (request != null) _load(request);
    }
    trackRoute();
  }

  @override
  void dispose() {
    releaseField();
    _discover?.dispose();
    _ctx?.dispose();
    super.dispose();
  }

  @override
  CoreField get sharedField => CoreField.discover;

  @override
  CoreClient? get coreClient => _client;

  @override
  CoreFieldNotifier? get fieldNotifier => _discover;

  @override
  DiscoverState parseField(Map<String, dynamic> json) =>
      DiscoverState.fromJson(json);

  /// Its `selected` is this screen's catalog (another screen's, or the
  /// unloaded field's null, is not -- and nothing is while rows are shown).
  @override
  bool isOwnState(DiscoverState state) {
    final selected = state.selected;
    return selected != null && _request != null && selected == _request;
  }

  /// Back on top: load this screen's catalog again, if it shows one.
  @override
  void reloadField() {
    final request = _request;
    if (request != null) _load(request);
  }

  /// Dispatches `Load CatalogWithFilters` for [request] and takes the
  /// field over.
  void _load(ResourceRequest request) {
    _request = request;
    // A load starts the catalog again from its first page, so a next page
    // asked for before it is not one this list is still waiting on.
    _nextPageRequestedAt = -1;
    claimField();
    _client?.dispatch(CoreActions.loadDiscover(request));
  }

  void _select(ResourceRequest request) => _load(request);

  /// Opens [request]'s catalog from the rows -- the catalog menu, or a
  /// row's "See all" -- with its type chosen.
  void _openCatalog(ResourceRequest request) {
    setState(() {
      _type = request.path.type;
      // What was on screen before is another catalog's, from before the
      // rows: nothing to show while this one is asked for.
      if (_request == null) ownState = null;
      _load(request);
    });
    // The field may hold this very catalog already -- another Discover
    // opened it and has not let it go -- and a `Load` of what is loaded
    // changes nothing, so no new state would come to say so.
    onFieldChanged();
  }

  /// Back to the rows of [type] (null: All), letting the catalog go.
  void _showRows(String? type) {
    setState(() {
      _type = type;
      if (_request == null) return;
      _request = null;
      releaseField();
    });
  }

  /// Back, on the tab: a catalog goes back to its type's rows, and a
  /// type's rows to All.
  void _back() {
    if (_showsCatalog) {
      _showRows(_type);
    } else if (_type != null) {
      _showRows(null);
    }
  }

  bool _onScroll(ScrollNotification notification, DiscoverState state) {
    if (notification.metrics.extentAfter < 600 &&
        state.hasNextPage &&
        !state.isLoadingMore &&
        _nextPageRequestedAt != state.pages.length) {
      _nextPageRequestedAt = state.pages.length;
      _client?.dispatch(CoreActions.loadDiscoverNextPage());
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      _browses ? _buildTab(context) : _buildPushed(context);

  /// A Discover pushed with a catalog: the engine's own filter bar over
  /// the grid.
  Widget _buildPushed(BuildContext context) {
    final state = ownState;
    final selectable = state?.selectable;
    final isTv = DeviceScope.isTv(context);
    return TvSafeArea(
      child: Scaffold(
        appBar: AppBar(title: Text(state?.selectedCatalogName ?? 'Discover')),
        body: Column(
          children: [
            if (selectable != null && !selectable.isEmpty)
              _tvGroup(
                isTv,
                // An addon installed or uninstalled while this screen is up
                // renames the headings in the catalog menu, and nothing
                // else here: only the bar listens to `ctx`, not the grid.
                ListenableBuilder(
                  listenable: _ctx!,
                  builder: (context, _) {
                    final ctx = _ctx!.value;
                    return _FilterBar(
                      selectable: selectable,
                      profile: ctx == null ? null : ProfileState.fromCtx(ctx),
                      onSelect: _select,
                    );
                  },
                ),
              ),
            Expanded(
              child: state == null
                  ? const Center(child: CircularProgressIndicator())
                  : _tvGroup(isTv, _buildCatalog(state)),
            ),
          ],
        ),
      ),
    );
  }

  /// The tab: types, the type's catalog menu and a catalog's filters over
  /// the rows or the catalog.
  Widget _buildTab(BuildContext context) {
    final state = ownState;
    final isTv = DeviceScope.isTv(context);
    final showsCatalog = _showsCatalog;
    return PopScope(
      // The shell never pops; this only takes the Back that reaches it.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: TvSafeArea(
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              showsCatalog
                  ? (state?.selectedCatalogName ?? 'Discover')
                  : 'Discover',
            ),
          ),
          body: Column(
            children: [
              _tvGroup(
                isTv,
                ListenableBuilder(
                  listenable: _ctx!,
                  builder: (context, _) {
                    final ctx = _ctx!.value;
                    return _BrowseHeader(
                      catalogs: ctx == null
                          ? DiscoverCatalogs.empty
                          : DiscoverCatalogs.of(ProfileState.fromCtx(ctx)),
                      type: _type,
                      request: _request,
                      selectable: showsCatalog ? state?.selectable : null,
                      onType: _showRows,
                      onCatalog: (request) => request == null
                          ? _showRows(_type)
                          : _openCatalog(request),
                      onFilter: _select,
                    );
                  },
                ),
              ),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Kept built under the catalog, so Back finds the rows
                    // where they were -- out of sight, out of the ticker
                    // and out of the remote's reach while the catalog is
                    // up.
                    ExcludeFocus(
                      excluding: showsCatalog,
                      child: Offstage(
                        offstage: showsCatalog,
                        child: TickerMode(
                          enabled: !showsCatalog,
                          child: _tvGroup(
                            isTv,
                            CatalogRows(
                              type: _type,
                              // The first tile takes the remote at start-up,
                              // this being the screen the app opens on.
                              defaultFocus: true,
                              onSeeAll: (row) => _openCatalog(row.firstRequest),
                              empty: _type == null ? null : const _NoRows(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (showsCatalog)
                      state == null
                          ? const Center(child: CircularProgressIndicator())
                          : _tvGroup(isTv, _buildCatalog(state)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [child] as its own traversal group on a TV; [child] itself elsewhere.
  static Widget _tvGroup(bool isTv, Widget child) =>
      isTv ? FocusTraversalGroup(child: child) : child;

  Widget _buildCatalog(DiscoverState state) {
    final items = state.items;
    final error = state.lastError;
    if (items.isEmpty) {
      if (error != null) return _ErrorView(message: error.message);
      // Either the first page is in flight or the field is still unloaded
      // (the state before the Load is answered looks exactly like a profile
      // with no catalogs, so no empty view is shown here).
      return const Center(child: CircularProgressIndicator());
    }
    // Pushed on top of another screen (never as the shell's tab, which is
    // part of the first route): the first poster is where TV focus starts.
    final isPushed = !_browses && ModalRoute.of(context)?.isFirst == false;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) => _onScroll(n, state),
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: posterGridDelegate,
        itemCount: items.length + (state.isLoadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= items.length) {
            return const Center(child: CircularProgressIndicator());
          }
          final item = items[index];
          return PosterTile(
            item: item,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MetaDetailsScreen(type: item.type, id: item.id),
              ),
            ),
            memoryId: '${item.type}/${item.id}',
            defaultFocus: isPushed && index == 0,
          );
        },
      ),
    );
  }
}

/// Types, catalogs of the selected type and the selected catalog's extras.
/// Stateless: [onSelect] gets the request the engine attached to the chosen
/// entry, and the bar re-renders from the next state's `selected` flags.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.selectable,
    required this.profile,
    required this.onSelect,
  });

  final DiscoverSelectable selectable;

  /// Names the addon behind each catalog; null before the profile has been
  /// read, when the menu falls back to the manifest URL's host.
  final ProfileState? profile;

  final ValueChanged<ResourceRequest> onSelect;

  /// Label of a non-required extra's `value: null` option.
  static const String anyOptionLabel = 'Any';

  static List<FilterOption<ResourceRequest>> _options(
    List<SelectableOption> options, {
    String Function(String label) label = _identity,
  }) => [
    for (final option in options)
      FilterOption(
        label: label(option.label),
        selected: option.selected,
        request: option.request,
      ),
  ];

  static String _identity(String label) => label;

  /// What the addon providing a catalog is called: the installed addon's
  /// own name, else the host of its manifest URL -- the same fallback the
  /// stream list uses for an addon that has been uninstalled since.
  String _addonName(String base) =>
      profile?.installedAddon(base)?.manifest.name ??
      Uri.tryParse(base)?.host ??
      base;

  /// The catalogs as menu entries, gathered under the addon that provides
  /// them.
  ///
  /// Gathered here rather than trusted to arrive that way: the engine lists
  /// the catalogs of every installed addon, and a heading drawn twice for
  /// one addon reads as two addons of the same name. With only one addon
  /// there is nothing to tell apart, so no heading is drawn at all.
  List<FilterOption<ResourceRequest>> _catalogOptions() {
    final byAddon = <String, List<SelectableOption>>{};
    for (final catalog in selectable.catalogs) {
      byAddon
          .putIfAbsent(_addonName(catalog.request.base), () => [])
          .add(catalog);
    }
    return [
      for (final addon in byAddon.entries)
        for (final catalog in addon.value)
          FilterOption(
            label: catalog.label,
            selected: catalog.selected,
            request: catalog.request,
            group: byAddon.length > 1 ? addon.key : null,
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.sizeOf(context).width >= FilterSegments.breakpoint;
    final types = _options(selectable.types, label: contentTypeLabel);
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
          if (selectable.catalogs.isNotEmpty)
            FilterMenu(
              label: 'Catalog',
              options: _catalogOptions(),
              onSelect: onSelect,
            ),
          for (final extra in selectable.extra)
            if (extra.options.isNotEmpty)
              FilterMenu(
                label: capitalise(extra.name),
                options: [
                  for (final option in extra.options)
                    FilterOption(
                      label: option.value ?? anyOptionLabel,
                      selected: option.selected,
                      request: option.request,
                    ),
                ],
                onSelect: onSelect,
              ),
        ],
      ),
    );
  }
}

/// The tab's header: the types, and under a type its catalog menu and the
/// open catalog's filters.
class _BrowseHeader extends StatelessWidget {
  const _BrowseHeader({
    required this.catalogs,
    required this.type,
    required this.request,
    required this.selectable,
    required this.onType,
    required this.onCatalog,
    required this.onFilter,
  });

  final DiscoverCatalogs catalogs;

  /// The type chosen; null is All.
  final String? type;

  /// The catalog open, or null for the rows.
  final ResourceRequest? request;

  /// The open catalog's filters, once the engine has described them.
  final DiscoverSelectable? selectable;

  final ValueChanged<String?> onType;

  /// A catalog was chosen from the menu; null is "Any", the rows.
  final ValueChanged<ResourceRequest?> onCatalog;

  /// A filter of the open catalog was chosen.
  final ValueChanged<ResourceRequest> onFilter;

  List<FilterOption<ResourceRequest?>> _catalogOptions(String type) {
    final ofType = catalogs.ofType(type);
    final addons = {for (final catalog in ofType) catalog.addonName};
    final open = request;
    return [
      FilterOption(
        label: DiscoverScreen.anyCatalogLabel,
        selected: open == null,
        request: null,
      ),
      for (final catalog in ofType)
        FilterOption(
          label: catalog.name,
          selected: open != null && catalog.isCatalogOf(open),
          request: catalog.request,
          // With one addon there is nothing to tell apart.
          group: addons.length > 1 ? catalog.addonName : null,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.sizeOf(context).width >= FilterSegments.breakpoint;
    final type = this.type;
    final types = <FilterOption<String?>>[
      FilterOption(
        label: DiscoverScreen.allTypesLabel,
        selected: type == null,
        request: null,
      ),
      for (final each in catalogs.types)
        FilterOption(
          label: contentTypeLabel(each),
          selected: type == each,
          request: each,
        ),
    ];
    // Two rungs on a television: the types, and the type's menus. The
    // menus start at the left edge while the chosen type may be far to its
    // right, and directional focus takes whatever is straight below -- the
    // rows -- stepping over the menus a press down was meant for. The rows
    // are no rung: a press down off the menus falls through to them.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: TvLadder(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TvLadderRow(
              level: _typesLevel,
              child: isWide
                  ? FilterSegments(options: types, onSelect: onType)
                  : FilterChips(options: types, onSelect: onType),
            ),
            if (type != null)
              TvLadderRow(
                level: _menusLevel,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilterMenu(
                        label: 'Catalog',
                        options: _catalogOptions(type),
                        onSelect: onCatalog,
                      ),
                      for (final extra
                          in selectable?.extra ?? const <SelectableExtra>[])
                        if (extra.options.isNotEmpty)
                          FilterMenu(
                            label: capitalise(extra.name),
                            options: [
                              for (final option in extra.options)
                                FilterOption(
                                  label:
                                      option.value ?? _FilterBar.anyOptionLabel,
                                  selected: option.selected,
                                  request: option.request,
                                ),
                            ],
                            onSelect: onFilter,
                          ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static const int _typesLevel = 0;
  static const int _menusLevel = 10;
}

/// A type whose catalogs all need a choice first has no rows to show.
class _NoRows extends StatelessWidget {
  const _NoRows();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          DiscoverScreen.noRowsLabel,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 48),
          const SizedBox(height: 12),
          Text(
            'Could not load this catalog',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
