import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../widgets/content_type_label.dart';
import '../../widgets/filter_controls.dart';
import '../../widgets/poster_tile.dart';
import '../details/meta_details_screen.dart';

/// Browses one catalog with its filters (`discover`, a `CatalogWithFilters`).
///
/// On mount it dispatches `Load CatalogWithFilters` for [request], or with
/// no selection so the engine picks the first catalog of the highest-priority
/// type. The engine answers with `selectable` (types, catalogs of that type,
/// the catalog's extra properties) where every entry carries the request
/// that selects it; the filter bar dispatches those verbatim and re-renders
/// from the next state, keeping no selection of its own. The pages of
/// `catalog` are a poster grid that loads the next page near the end of the
/// scroll. The field is unloaded on dispose.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, this.request});

  /// Catalog to open; null lets the engine choose.
  final ResourceRequest? request;

  /// From this width on, types are a segmented button rather than chips.
  static const double wideBreakpoint = 720;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _discover;
  int _nextPageRequestedAt = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _discover?.dispose();
      _client = client;
      _discover = CoreFieldNotifier(client, CoreField.discover);
      final request = widget.request;
      client.dispatch(
        request == null
            ? CoreActions.loadDiscoverDefault()
            : CoreActions.loadDiscover(request),
      );
    }
  }

  @override
  void dispose() {
    _client?.dispatch(CoreActions.unload(CoreField.discover));
    _discover?.dispose();
    super.dispose();
  }

  void _select(ResourceRequest request) {
    _nextPageRequestedAt = -1;
    _client?.dispatch(CoreActions.loadDiscover(request));
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
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: _discover!,
      builder: (context, json, _) {
        final state = json == null ? null : DiscoverState.fromJson(json);
        final selectable = state?.selectable;
        return Scaffold(
          appBar: AppBar(title: Text(state?.selectedCatalogName ?? 'Discover')),
          body: Column(
            children: [
              if (selectable != null && !selectable.isEmpty)
                _FilterBar(selectable: selectable, onSelect: _select),
              Expanded(
                child: state == null
                    ? const Center(child: CircularProgressIndicator())
                    : _buildCatalog(state),
              ),
            ],
          ),
        );
      },
    );
  }

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
  const _FilterBar({required this.selectable, required this.onSelect});

  final DiscoverSelectable selectable;
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

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.sizeOf(context).width >= DiscoverScreen.wideBreakpoint;
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
              options: _options(selectable.catalogs),
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
