import '../../core/core.dart';

/// One catalog Discover can open: the request that opens it, and what to
/// call it and the addon behind it.
final class DiscoverCatalog {
  const DiscoverCatalog({
    required this.name,
    required this.addonName,
    required this.request,
  });

  /// The manifest's name for the catalog, else its id.
  final String name;
  final String addonName;

  /// What `Load CatalogWithFilters` takes to open it: the catalog, with
  /// each required property at its first option.
  final ResourceRequest request;

  String get type => request.path.type;

  /// Whether [other] names this catalog, whatever its filters are set to.
  bool isCatalogOf(ResourceRequest other) =>
      other.base == request.base &&
      other.path.id == request.path.id &&
      other.path.type == request.path.type &&
      other.path.resource == request.path.resource;
}

/// Every catalog Discover can open, and the types they come in, read off
/// the installed addons' manifests.
///
/// **The same rule stremio-core applies to Discover's own menu**
/// (`catalog_with_filters::selectable_update`): a catalog is on offer when
/// it can be opened with nothing typed in -- every required property has
/// options to start from -- in the order the addons are installed and the
/// order each manifest lists its catalogs. So a catalog that needs a genre
/// is here, opened on its first genre, and a search-only one is not.
///
/// Read here rather than off the engine's `selectable` because Discover
/// has to show the types and a type's catalogs before any catalog is
/// loaded -- the engine only describes what surrounds the one catalog it
/// holds.
final class DiscoverCatalogs {
  const DiscoverCatalogs(this.catalogs);

  /// Nothing installed, or the profile not read yet.
  static const DiscoverCatalogs empty = DiscoverCatalogs([]);

  factory DiscoverCatalogs.of(ProfileState profile) => DiscoverCatalogs([
    for (final addon in profile.addons)
      for (final catalog in addon.manifest.catalogs)
        if (catalog.defaultRequiredExtra case final extra?)
          DiscoverCatalog(
            name: catalog.name ?? catalog.id,
            addonName: addon.manifest.name.isEmpty
                ? (Uri.tryParse(addon.transportUrl)?.host ?? addon.transportUrl)
                : addon.manifest.name,
            request: ResourceRequest(
              base: addon.transportUrl,
              path: ResourcePath(
                resource: 'catalog',
                type: catalog.type,
                id: catalog.id,
                extra: extra,
              ),
            ),
          ),
  ]);

  final List<DiscoverCatalog> catalogs;

  /// The type an addon may declare that would read as the "All" choice
  /// itself. Left off the type chips: its catalogs are among All's rows,
  /// and a second "All" beside the first would say two different things.
  static const String allType = 'all';

  /// The types of [catalogs], each once, in stremio-core's order: the
  /// known ones by rank (movies, series, channels, TV), then any other
  /// alphabetically, and `other` last -- `TYPE_PRIORITIES` as
  /// `compare_with_priorities` applies it, which is the order Discover's
  /// own type list has.
  List<String> get types {
    final seen = <String>{};
    final types = [
      for (final catalog in catalogs)
        if (catalog.type != allType && seen.add(catalog.type)) catalog.type,
    ];
    return types..sort(compareTypes);
  }

  /// The catalogs of [type], in install order.
  List<DiscoverCatalog> ofType(String type) => [
    for (final catalog in catalogs)
      if (catalog.type == type) catalog,
  ];

  /// The ranks `TYPE_PRIORITIES` gives, highest first once sorted.
  static const Map<String, int> _ranks = {
    'movie': 4,
    'series': 3,
    'channel': 2,
    'tv': 1,
  };

  /// [a] before [b] in stremio-core's type order.
  static int compareTypes(String a, String b) {
    int group(String type) => type == 'other'
        ? 2
        : _ranks.containsKey(type)
        ? 0
        : 1;
    final byGroup = group(a).compareTo(group(b));
    if (byGroup != 0) return byGroup;
    if (group(a) == 0) return _ranks[b]!.compareTo(_ranks[a]!);
    return a.compareTo(b);
  }
}
