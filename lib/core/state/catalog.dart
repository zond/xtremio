import '../resource.dart';
import 'loadable.dart';
import 'meta_item_preview.dart';

/// One page of a catalog: stremio-core's `ResourceLoadable<Vec<T>>`.
final class CatalogPage extends ResourceLoadable<List<MetaItemPreview>> {
  const CatalogPage({required super.request, required super.content});

  factory CatalogPage.fromJson(Map<String, dynamic> json) {
    final loadable = ResourceLoadable.fromJson(
      json,
      MetaItemPreview.listFromJson,
    );
    return CatalogPage(request: loadable.request, content: loadable.content);
  }
}

/// One entry of `selectable.types` / `selectable.catalogs` / an extra's
/// `options`: the request that loads it and whether it is the current one.
/// The UI never tracks selection itself; it dispatches [request] and renders
/// the next state's `selected` flags.
final class SelectableOption {
  const SelectableOption({
    required this.label,
    required this.selected,
    required this.request,
  });

  /// Display label: the type, the catalog name, or the extra value.
  final String label;
  final bool selected;

  /// The request to dispatch (`Load CatalogWithFilters`) to select this.
  final ResourceRequest request;

  static SelectableOption _fromJson(Map<String, dynamic> json, String label) =>
      SelectableOption(
        label: label,
        selected: json['selected'] as bool? ?? false,
        request: ResourceRequest.fromJson(
          json['request'] as Map<String, dynamic>,
        ),
      );
}

/// One extra property of the selected catalog with options (`genre`, ...).
final class SelectableExtra {
  const SelectableExtra({
    required this.name,
    required this.isRequired,
    required this.options,
  });

  /// The extra's name as the manifest declares it (`genre`).
  final String name;

  /// When false the engine adds a `value: null` option that clears the
  /// extra; when true one of the values is always applied.
  final bool isRequired;

  /// Options in manifest order; a null value means "no filter".
  final List<SelectableExtraOption> options;

  factory SelectableExtra.fromJson(Map<String, dynamic> json) =>
      SelectableExtra(
        name: json['name'] as String,
        isRequired: json['isRequired'] as bool? ?? false,
        options: [
          for (final option in (json['options'] as List<dynamic>? ?? const []))
            SelectableExtraOption.fromJson(option as Map<String, dynamic>),
        ],
      );

  SelectableExtraOption? get selectedOption =>
      options.where((option) => option.selected).firstOrNull;
}

/// One value of a [SelectableExtra].
final class SelectableExtraOption {
  const SelectableExtraOption({
    required this.value,
    required this.selected,
    required this.request,
  });

  /// The extra's value, or null for the "any" option of a non-required
  /// extra.
  final String? value;
  final bool selected;
  final ResourceRequest request;

  factory SelectableExtraOption.fromJson(Map<String, dynamic> json) =>
      SelectableExtraOption(
        value: json['value'] as String?,
        selected: json['selected'] as bool? ?? false,
        request: ResourceRequest.fromJson(
          json['request'] as Map<String, dynamic>,
        ),
      );
}

/// The filters stremio-core offers for the loaded catalog
/// (`CatalogWithFilters.selectable`): every type across the installed
/// addons, the catalogs of the selected type, the selected catalog's extra
/// properties, and the next page when there is one.
final class DiscoverSelectable {
  const DiscoverSelectable({
    required this.types,
    required this.catalogs,
    required this.extra,
    required this.nextPage,
  });

  const DiscoverSelectable.empty()
    : types = const [],
      catalogs = const [],
      extra = const [],
      nextPage = null;

  final List<SelectableOption> types;
  final List<SelectableOption> catalogs;
  final List<SelectableExtra> extra;

  /// Request for the next page, when the addon offers one.
  final ResourceRequest? nextPage;

  factory DiscoverSelectable.fromJson(Map<String, dynamic> json) {
    final nextPage = json['nextPage'] as Map<String, dynamic>?;
    return DiscoverSelectable(
      types: [
        for (final type in (json['types'] as List<dynamic>? ?? const []))
          SelectableOption._fromJson(
            type as Map<String, dynamic>,
            type['type'] as String,
          ),
      ],
      catalogs: [
        for (final catalog in (json['catalogs'] as List<dynamic>? ?? const []))
          SelectableOption._fromJson(
            catalog as Map<String, dynamic>,
            catalog['catalog'] as String,
          ),
      ],
      extra: [
        for (final extra in (json['extra'] as List<dynamic>? ?? const []))
          SelectableExtra.fromJson(extra as Map<String, dynamic>),
      ],
      nextPage: nextPage == null
          ? null
          : ResourceRequest.fromJson(
              nextPage['request'] as Map<String, dynamic>,
            ),
    );
  }

  SelectableOption? get selectedType =>
      types.where((type) => type.selected).firstOrNull;

  SelectableOption? get selectedCatalog =>
      catalogs.where((catalog) => catalog.selected).firstOrNull;

  /// Nothing to offer: no installed addon has a catalog.
  bool get isEmpty => types.isEmpty && catalogs.isEmpty && extra.isEmpty;
}

/// View over the `discover` field (`CatalogWithFilters<MetaItemPreview>`).
final class DiscoverState {
  const DiscoverState({
    required this.selected,
    required this.pages,
    required this.selectable,
  });

  /// The request that was loaded, or null when the model is unloaded.
  final ResourceRequest? selected;

  /// Loaded pages, in order; the last may still be loading.
  final List<CatalogPage> pages;

  /// The filters to offer for [selected].
  final DiscoverSelectable selectable;

  factory DiscoverState.fromJson(Map<String, dynamic> json) {
    final selected = json['selected'] as Map<String, dynamic>?;
    final selectable = json['selectable'] as Map<String, dynamic>?;
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
      selectable: selectable == null
          ? const DiscoverSelectable.empty()
          : DiscoverSelectable.fromJson(selectable),
    );
  }

  /// Every item of every ready page.
  List<MetaItemPreview> get items => [
    for (final page in pages) ...?page.contentOrNull,
  ];

  bool get isLoadingMore => pages.isNotEmpty && pages.last.isLoading;

  LoadableError<List<MetaItemPreview>>? get lastError =>
      pages.isNotEmpty ? pages.last.error : null;

  /// Request for the next page, when the addon offers one.
  ResourceRequest? get nextPage => selectable.nextPage;

  bool get hasNextPage => nextPage != null;

  /// Name of the loaded catalog (`manifest_catalog.name ?? id`), when known.
  String? get selectedCatalogName => selectable.selectedCatalog?.label;
}
