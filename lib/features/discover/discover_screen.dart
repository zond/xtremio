import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../widgets/poster_tile.dart';
import '../details/meta_details_screen.dart';

/// Browses one catalog: dispatches `Load CatalogWithFilters` for [request]
/// on mount, renders the pages of `discover.catalog` as a poster grid,
/// loads the next page near the end of the scroll, and unloads on dispose.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, this.request});

  /// Catalog to show; defaults to Cinemeta's top movies.
  final ResourceRequest? request;

  static final ResourceRequest defaultRequest = ResourceRequest.cinemetaCatalog(
    type: 'movie',
    id: 'top',
  );

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _discover;
  int _nextPageRequestedAt = -1;

  ResourceRequest get _request =>
      widget.request ?? DiscoverScreen.defaultRequest;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _discover?.dispose();
      _client = client;
      _discover = CoreFieldNotifier(client, CoreField.discover);
      client.dispatch(CoreActions.loadDiscover(_request));
    }
  }

  @override
  void dispose() {
    _client?.dispatch(CoreActions.unload(CoreField.discover));
    _discover?.dispose();
    super.dispose();
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
    return Scaffold(
      appBar: AppBar(title: const Text('Discover')),
      body: ValueListenableBuilder<Map<String, dynamic>?>(
        valueListenable: _discover!,
        builder: (context, json, _) {
          if (json == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final state = DiscoverState.fromJson(json);
          final items = state.items;
          final error = state.lastError;
          if (items.isEmpty) {
            if (error != null) return _ErrorView(message: error.message);
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
                      builder: (_) =>
                          MetaDetailsScreen(type: item.type, id: item.id),
                    ),
                  ),
                );
              },
            ),
          );
        },
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
