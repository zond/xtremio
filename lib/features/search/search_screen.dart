import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../widgets/content_type_label.dart';
import '../../widgets/poster_tile.dart';
import '../details/meta_details_screen.dart';

/// Searches every installed addon that supports the `search` extra
/// (`search`, a `CatalogsWithExtra` like the board).
///
/// The query is debounced ([debounce]) because every `Load` also pushes the
/// query to the profile's search history; Enter searches at once. A `Load`
/// only plans one catalog per addon, so as soon as the engine reports the
/// planned catalogs for the current query a `LoadRange` over all of them is
/// dispatched, exactly once per query. Results are one poster grid per
/// catalog that answered, labelled from `catalogLabels`; catalogs that
/// answered with nothing are skipped, failed ones keep a compact error. An
/// empty query unloads the field, as does leaving the screen.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  /// Pause in typing before the query is sent to the engine.
  static const Duration debounce = Duration(milliseconds: 400);

  /// Name of the extra the engine searches by.
  static const String searchExtra = 'search';

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _search;
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  /// The query the engine was last asked to load; null after an unload.
  String? _lastDispatched;

  /// The query whose planned catalogs have been requested with `LoadRange`.
  String? _rangeRequestedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _search?.removeListener(_requestRangeIfPlanned);
      _search?.dispose();
      _client = client;
      _search = CoreFieldNotifier(client, CoreField.search)
        ..addListener(_requestRangeIfPlanned);
      _lastDispatched = null;
      _rangeRequestedFor = null;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _client?.dispatch(CoreActions.unload(CoreField.search));
    _search?.removeListener(_requestRangeIfPlanned);
    _search?.dispose();
    super.dispose();
  }

  CatalogsWithExtraState? get _state {
    final json = _search?.value;
    return json == null ? null : CatalogsWithExtraState.fromJson(json);
  }

  /// The query a `search` state was loaded for, or null when unloaded.
  static String? queryOf(CatalogsWithExtraState state) => state.isLoaded
      ? state.selectedExtra
            .where((extra) => extra.name == SearchScreen.searchExtra)
            .firstOrNull
            ?.value
      : null;

  void _onTextChanged(String text) {
    _debounce?.cancel();
    final query = text.trim();
    if (query.isEmpty) {
      _clear();
    } else {
      _debounce = Timer(SearchScreen.debounce, () => _submit(query));
    }
    setState(() {});
  }

  /// Enter: no need to wait for the pause.
  void _onSubmitted(String text) {
    _debounce?.cancel();
    final query = text.trim();
    if (query.isEmpty) {
      _clear();
    } else {
      _submit(query);
    }
  }

  void _submit(String query) {
    if (!mounted || query == _lastDispatched) return;
    _lastDispatched = query;
    _rangeRequestedFor = null;
    _client?.dispatch(CoreActions.loadSearch(query));
    // The engine may already hold this query's plan (a repeated search);
    // otherwise the next state will trigger the range.
    _requestRangeIfPlanned();
    setState(() {});
  }

  void _clear() {
    if (_lastDispatched != null) {
      _client?.dispatch(CoreActions.unload(CoreField.search));
    }
    _lastDispatched = null;
    _rangeRequestedFor = null;
  }

  void _clearField() {
    _controller.clear();
    _onTextChanged('');
  }

  /// Once the engine has planned the catalogs for the query in flight, ask
  /// for every one of them (search rows are few).
  void _requestRangeIfPlanned() {
    final query = _lastDispatched;
    final state = _state;
    if (query == null ||
        state == null ||
        queryOf(state) != query ||
        _rangeRequestedFor == query ||
        state.rows.isEmpty) {
      return;
    }
    _rangeRequestedFor = query;
    _client?.dispatch(CoreActions.loadSearchRange(0, state.rows.last.index));
  }

  void _openDetails(MetaItemPreview item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MetaDetailsScreen(type: item.type, id: item.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: _search!,
      builder: (context, json, _) {
        final query = _lastDispatched;
        final state = json == null
            ? null
            : CatalogsWithExtraState.fromJson(json);
        // Results are for the query in flight only; anything else the engine
        // holds (a previous query, nothing at all) counts as loading.
        final current = state != null && queryOf(state) == query ? state : null;
        final isLoading =
            query != null &&
            (current == null ||
                current.rows.any((row) => row.isPlanned || row.isLoading));
        return Scaffold(
          appBar: AppBar(
            title: _SearchField(
              controller: _controller,
              onChanged: _onTextChanged,
              onSubmitted: _onSubmitted,
              onClear: _clearField,
            ),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(_progressHeight),
              child: isLoading
                  ? const LinearProgressIndicator(minHeight: _progressHeight)
                  : const SizedBox(height: _progressHeight),
            ),
          ),
          body: query == null
              ? const _SearchHint()
              : current == null
              ? const SizedBox.expand()
              : _Results(
                  query: query,
                  state: current,
                  isLoading: isLoading,
                  onOpen: _openDetails,
                ),
        );
      },
    );
  }

  static const double _progressHeight = 3;
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => TextField(
    key: const Key('search-field'),
    controller: controller,
    // A keyboard is right there on a desktop or phone. On a TV taking focus
    // as soon as the tab is selected would pull it off the rail, which no
    // other tab does, and open the IME; the D-pad enters the field instead.
    autofocus: !DeviceScope.isTv(context),
    textInputAction: TextInputAction.search,
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    decoration: InputDecoration(
      hintText: 'Search',
      border: InputBorder.none,
      prefixIcon: const Icon(Icons.search),
      suffixIcon: controller.text.isEmpty
          ? null
          : IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.close),
              onPressed: onClear,
            ),
    ),
  );
}

/// One grid per catalog that returned items, plus a compact error for any
/// that failed; catalogs with no hits are left out.
class _Results extends StatelessWidget {
  const _Results({
    required this.query,
    required this.state,
    required this.isLoading,
    required this.onOpen,
  });

  final String query;
  final CatalogsWithExtraState state;
  final bool isLoading;
  final ValueChanged<MetaItemPreview> onOpen;

  @override
  Widget build(BuildContext context) {
    final sections = [
      for (final row in state.rows)
        if (row.items.isNotEmpty || (row.error != null && !row.isEmpty)) row,
    ];
    if (sections.isEmpty) {
      return isLoading ? const SizedBox.expand() : _NoResults(query: query);
    }
    return CustomScrollView(
      key: const Key('search-results'),
      slivers: [
        for (final row in sections) ...[
          SliverToBoxAdapter(child: _SectionHeader(row: row)),
          if (row.error case final error?)
            SliverToBoxAdapter(child: _SectionError(message: error.message))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 160,
                  childAspectRatio: 0.56,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                ),
                itemCount: row.items.length,
                itemBuilder: (context, index) {
                  final item = row.items[index];
                  return PosterTile(item: item, onTap: () => onOpen(item));
                },
              ),
            ),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
      ],
    );
  }
}

/// `Movies · Cinemeta`: the content type and the addon that answered.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.row});

  final CatalogRow row;

  static String titleFor(CatalogRow row) {
    final label = row.label;
    final type = label?.type ?? row.firstRequest.path.type;
    final addon =
        label?.addonName ??
        Uri.tryParse(row.firstRequest.base)?.host ??
        row.firstRequest.base;
    return [
      if (type.isNotEmpty) contentTypeLabel(type),
      if (addon.isNotEmpty) addon,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(
      titleFor(row),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium,
    ),
  );
}

class _SectionError extends StatelessWidget {
  const _SectionError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: const Icon(Icons.cloud_off_outlined),
    title: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
  );
}

class _SearchHint extends StatelessWidget {
  const _SearchHint();

  @override
  Widget build(BuildContext context) => const _CenteredMessage(
    icon: Icons.search,
    title: 'Search movies, series and channels',
    detail: 'Results come from every installed addon that supports search.',
  );
}

class _NoResults extends StatelessWidget {
  const _NoResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) => _CenteredMessage(
    icon: Icons.search_off,
    title: 'No results for “$query”',
    detail: 'Try another spelling, or install an addon that covers it.',
  );
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              detail,
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
