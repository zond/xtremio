import '../resource.dart';
import 'addon_descriptor.dart';
import 'catalog.dart';
import 'loadable.dart';

/// One page of an addon catalog: `ResourceLoadable<Vec<Descriptor>>`.
final class RemoteAddonsPage extends ResourceLoadable<List<AddonDescriptor>> {
  const RemoteAddonsPage({required super.request, required super.content});

  factory RemoteAddonsPage.fromJson(Map<String, dynamic> json) {
    final loadable = ResourceLoadable.fromJson(
      json,
      AddonDescriptor.listFromJson,
    );
    return RemoteAddonsPage(
      request: loadable.request,
      content: loadable.content,
    );
  }
}

/// View over the `remote_addons` field (`CatalogWithFilters<Descriptor>`):
/// the same shape as Discover (camelCase, `selectable.nextPage`), over an
/// `addon_catalog` resource. Whether an entry is installed is not part of
/// the model; compare against `ProfileState.addons` by manifest URL.
final class RemoteAddonsState {
  const RemoteAddonsState({
    required this.selected,
    required this.pages,
    required this.selectable,
  });

  /// The loaded request, or null when the model is unloaded.
  final ResourceRequest? selected;

  final List<RemoteAddonsPage> pages;

  /// Catalogs (`Official`, `Community`, ...) and types to offer.
  final DiscoverSelectable selectable;

  factory RemoteAddonsState.fromJson(Map<String, dynamic> json) {
    final selected = json['selected'] as Map<String, dynamic>?;
    final selectable = json['selectable'] as Map<String, dynamic>?;
    return RemoteAddonsState(
      selected: selected == null
          ? null
          : ResourceRequest.fromJson(
              selected['request'] as Map<String, dynamic>,
            ),
      pages: [
        for (final page in (json['catalog'] as List<dynamic>? ?? const []))
          RemoteAddonsPage.fromJson(page as Map<String, dynamic>),
      ],
      selectable: selectable == null
          ? const DiscoverSelectable.empty()
          : DiscoverSelectable.fromJson(selectable),
    );
  }

  bool get isLoaded => selected != null;

  /// Every descriptor of every ready page.
  List<AddonDescriptor> get addons => [
    for (final page in pages) ...?page.contentOrNull,
  ];

  bool get isLoading => pages.isNotEmpty && pages.last.isLoading;

  LoadableError<List<AddonDescriptor>>? get lastError =>
      pages.isNotEmpty ? pages.last.error : null;

  ResourceRequest? get nextPage => selectable.nextPage;
}
