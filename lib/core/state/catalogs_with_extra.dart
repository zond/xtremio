import '../resource.dart';
import 'catalog.dart';
import 'loadable.dart';
import 'meta_item_preview.dart';

/// The name of one board/search row, from the `catalogLabels` projection
/// the Rust side adds next to `catalogs` (resolved from the profile's
/// addon manifests; the raw model only carries requests).
final class CatalogLabel {
  const CatalogLabel({
    required this.name,
    required this.addonName,
    required this.type,
  });

  /// The manifest catalog's name, or the addon's when it has none.
  final String name;
  final String addonName;

  /// The catalog's content type (`movie`, `series`, `channel`, ...).
  final String type;

  factory CatalogLabel.fromJson(Map<String, dynamic> json) => CatalogLabel(
    name: json['name'] as String? ?? '',
    addonName: json['addonName'] as String? ?? '',
    type: json['type'] as String? ?? '',
  );
}

/// One catalog of a `CatalogsWithExtra` model: its pages plus its label.
final class CatalogRow {
  const CatalogRow({
    required this.index,
    required this.pages,
    required this.label,
  });

  /// Position in `catalogs`, the index `LoadRange`/`LoadNextPage` address.
  final int index;

  /// At least one page; only the first is planned by `Load`, later ones come
  /// from `LoadNextPage`.
  final List<CatalogPage> pages;

  final CatalogLabel? label;

  /// The request that identifies this catalog (the first page's).
  ResourceRequest get firstRequest => pages.first.request;

  /// Row title: the catalog's name, falling back to its id.
  String get title => label?.name ?? firstRequest.path.id;

  /// `Addon · type`, for the row's subtitle.
  String get subtitle {
    final label = this.label;
    final type = label?.type ?? firstRequest.path.type;
    final addon =
        label?.addonName ??
        Uri.tryParse(firstRequest.base)?.host ??
        firstRequest.base;
    return [if (addon.isNotEmpty) addon, if (type.isNotEmpty) type].join(' · ');
  }

  /// Planned by `Load` but outside every `LoadRange` so far: nothing has
  /// been requested.
  bool get isPlanned => pages.first.content == null;

  /// A request is in flight (the first page, or a later one).
  bool get isLoading => pages.any((page) => page.content?.isLoading ?? false);

  /// Every item of every ready page, in order.
  List<MetaItemPreview> get items => [
    for (final page in pages) ...?page.contentOrNull,
  ];

  /// The first page's error, when it failed.
  LoadableError<List<MetaItemPreview>>? get error => pages.first.error;

  /// The addon answered but has nothing for this catalog; the row can be
  /// dropped silently.
  bool get isEmpty => error?.isEmptyContent ?? false;

  /// The shape the row's tiles should use: that of the first item, as
  /// stremio-web does, so one row is uniform.
  String get posterShape {
    final items = this.items;
    return items.isEmpty ? 'poster' : items.first.posterShape;
  }
}

/// View over a `CatalogsWithExtra` field (`board`, `search`) plus the
/// `catalogLabels` projection.
final class CatalogsWithExtraState {
  const CatalogsWithExtraState({
    required this.selectedType,
    required this.selectedExtra,
    required this.isLoaded,
    required this.rows,
  });

  /// The type filter that was loaded (null = every type).
  final String? selectedType;

  /// The extras that were loaded (e.g. `[search, query]`).
  final List<ExtraValue> selectedExtra;

  /// False when the model is unloaded (`selected == null`).
  final bool isLoaded;

  /// One per catalog the engine planned, in `catalogs` order.
  final List<CatalogRow> rows;

  factory CatalogsWithExtraState.fromJson(Map<String, dynamic> json) {
    final selected = json['selected'] as Map<String, dynamic>?;
    final labels = json['catalogLabels'] as List<dynamic>? ?? const [];
    final catalogs = json['catalogs'] as List<dynamic>? ?? const [];
    return CatalogsWithExtraState(
      selectedType: selected?['type'] as String?,
      selectedExtra: [
        for (final value in (selected?['extra'] as List<dynamic>? ?? const []))
          ExtraValue.fromJson(value),
      ],
      isLoaded: selected != null,
      rows: [
        for (final (index, pages) in catalogs.indexed)
          if ((pages as List<dynamic>).isNotEmpty)
            CatalogRow(
              index: index,
              pages: [
                for (final page in pages)
                  CatalogPage.fromJson(page as Map<String, dynamic>),
              ],
              label: index < labels.length && labels[index] != null
                  ? CatalogLabel.fromJson(labels[index] as Map<String, dynamic>)
                  : null,
            ),
      ],
    );
  }

  /// Rows worth a place on screen: everything but the ones whose addon
  /// answered with no items.
  List<CatalogRow> get visibleRows => [
    for (final row in rows)
      if (!row.isEmpty) row,
  ];

  /// Any page still being fetched.
  bool get isLoading => rows.any((row) => row.isLoading);
}
