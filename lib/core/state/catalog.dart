import '../resource.dart';
import 'loadable.dart';
import 'meta_item_preview.dart';

/// One page of a catalog: stremio-core's `ResourceLoadable<Vec<T>>`.
final class CatalogPage {
  const CatalogPage({required this.request, required this.content});

  final ResourceRequest request;
  final Loadable<List<MetaItemPreview>> content;

  factory CatalogPage.fromJson(Map<String, dynamic> json) => CatalogPage(
    request: ResourceRequest.fromJson(json['request'] as Map<String, dynamic>),
    content: Loadable.fromJson(
      json['content'] as Map<String, dynamic>?,
      MetaItemPreview.listFromJson,
    ),
  );
}

/// View over the `discover` field (`CatalogWithFilters<MetaItemPreview>`).
final class DiscoverState {
  const DiscoverState({
    required this.selected,
    required this.pages,
    required this.nextPage,
  });

  /// The request that was loaded, or null when the model is unloaded.
  final ResourceRequest? selected;

  /// Loaded pages, in order; the last may still be loading.
  final List<CatalogPage> pages;

  /// Request for the next page, when the addon offers one.
  final ResourceRequest? nextPage;

  factory DiscoverState.fromJson(Map<String, dynamic> json) {
    final selected = json['selected'] as Map<String, dynamic>?;
    final selectable = json['selectable'] as Map<String, dynamic>?;
    final nextPage = selectable?['nextPage'] as Map<String, dynamic>?;
    return DiscoverState(
      selected: selected == null
          ? null
          : ResourceRequest.fromJson(
              selected['request'] as Map<String, dynamic>,
            ),
      pages: [
        for (final page in (json['catalog'] as List<dynamic>? ?? const []))
          CatalogPage.fromJson(page as Map<String, dynamic>),
      ],
      nextPage: nextPage == null
          ? null
          : ResourceRequest.fromJson(
              nextPage['request'] as Map<String, dynamic>,
            ),
    );
  }

  /// Every item of every ready page.
  List<MetaItemPreview> get items => [
    for (final page in pages) ...?page.content.contentOrNull,
  ];

  bool get isLoadingMore => pages.isNotEmpty && pages.last.content.isLoading;

  LoadableError<List<MetaItemPreview>>? get lastError =>
      pages.isNotEmpty && pages.last.content is LoadableError
      ? pages.last.content as LoadableError<List<MetaItemPreview>>
      : null;

  bool get hasNextPage => nextPage != null;
}
