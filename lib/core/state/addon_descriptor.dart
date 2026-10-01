import '../resource.dart';
import '../well_formed_text.dart';

/// View over stremio-core's `Descriptor` JSON (camelCase): a manifest, the
/// manifest URL it was fetched from, and the official/protected flags. The
/// raw map is kept because `InstallAddon` / `UninstallAddon` /
/// `UpgradeAddon` take the whole descriptor back.
final class AddonDescriptor {
  const AddonDescriptor(this.json);

  final Map<String, dynamic> json;

  AddonManifest get manifest =>
      AddonManifest(json['manifest'] as Map<String, dynamic>? ?? const {});

  String get transportUrl => json['transportUrl'] as String;

  Map<String, dynamic> get _flags =>
      json['flags'] as Map<String, dynamic>? ?? const {};

  /// Shipped with the app (`OFFICIAL_ADDONS`).
  bool get isOfficial => _flags['official'] as bool? ?? false;

  /// Cannot be uninstalled (Cinemeta, the local addon).
  bool get isProtected => _flags['protected'] as bool? ?? false;

  /// The addon's configuration page, when it has one: the manifest URL with
  /// its first `manifest.json` replaced by `configure` (so a query string
  /// after it survives), as stremio-web opens it. Null when the manifest
  /// declares neither `configurable` nor `configurationRequired`.
  String? get configureUrl {
    final hints = manifest.behaviorHints;
    if (!hints.configurable && !hints.configurationRequired) return null;
    return transportUrl.replaceFirst('manifest.json', 'configure');
  }

  /// Same addon: descriptors are keyed by manifest URL.
  bool isSameAddon(AddonDescriptor other) => other.transportUrl == transportUrl;

  static List<AddonDescriptor> listFromJson(Object? json) => [
    for (final item in (json as List<dynamic>? ?? const []))
      AddonDescriptor(item as Map<String, dynamic>),
  ];
}

/// View over a `Manifest` (camelCase).
final class AddonManifest {
  const AddonManifest(this.json);

  final Map<String, dynamic> json;

  String get id => json['id'] as String? ?? '';
  String get version => json['version'] as String? ?? '';
  String get name => wellFormedText(json['name'] as String?) ?? '';
  String? get description => wellFormedText(json['description'] as String?);
  String? get contactEmail => json['contactEmail'] as String?;
  String? get logo => json['logo'] as String?;
  String? get background => json['background'] as String?;

  /// Meta types the addon serves (`movie`, `series`, ...).
  List<String> get types => [
    ...?(json['types'] as List<dynamic>?)?.whereType<String>(),
  ];

  /// Resource names (`catalog`, `meta`, `stream`, `subtitles`,
  /// `addon_catalog`), whether declared in the short or the long form.
  List<String> get resourceNames => [
    for (final resource in (json['resources'] as List<dynamic>? ?? const []))
      if (resource is String)
        resource
      else if (resource is Map<String, dynamic> && resource['name'] is String)
        resource['name'] as String,
  ];

  /// Whether [resources] offers [resourceName] for [type], mirroring
  /// stremio-core's `Manifest::is_resource_supported` (minus the id-prefix
  /// half, which needs an id this call has none of): a short-form entry
  /// (`"stream"`) falls back to [types]; a long-form entry
  /// (`{name, types}`) answers for its own `types` list alone -- one
  /// declared with no `types` of its own supports nothing, same as the
  /// Rust side.
  bool offersResourceForType(String resourceName, String type) {
    for (final resource in (json['resources'] as List<dynamic>? ?? const [])) {
      if (resource is String) {
        if (resource == resourceName) return types.contains(type);
      } else if (resource is Map<String, dynamic> &&
          resource['name'] == resourceName) {
        final declared = resource['types'] as List<dynamic>?;
        return declared != null && declared.whereType<String>().contains(type);
      }
    }
    return false;
  }

  List<ManifestCatalog> get catalogs =>
      ManifestCatalog.listFromJson(json['catalogs']);

  /// Catalogs of addons (the community list lives in Cinemeta's).
  List<ManifestCatalog> get addonCatalogs =>
      ManifestCatalog.listFromJson(json['addonCatalogs']);

  ManifestBehaviorHints get behaviorHints => ManifestBehaviorHints(
    json['behaviorHints'] as Map<String, dynamic>? ?? const {},
  );
}

/// One `ManifestCatalog`: id and type, plus the display name when given.
final class ManifestCatalog {
  const ManifestCatalog(this.json);

  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get type => json['type'] as String;
  String? get name => json['name'] as String?;

  /// The extra properties the catalog takes, from either form a manifest
  /// may use: the full `extra` list, or the short `extraRequired` /
  /// `extraSupported` pair, whose properties have no options -- which is
  /// how stremio-core reads them (`ManifestExtra::iter`).
  List<ManifestExtraProp> get extraProps {
    final full = json['extra'];
    if (full is List) {
      return [
        for (final prop in full)
          if (prop is Map<String, dynamic> && prop['name'] is String)
            ManifestExtraProp(
              name: prop['name'] as String,
              isRequired: prop['isRequired'] == true,
              options: [...?(prop['options'] as List?)?.whereType<String>()],
            ),
      ];
    }
    final required = {
      ...?(json['extraRequired'] as List?)?.whereType<String>(),
    };
    return [
      for (final name
          in (json['extraSupported'] as List?)?.whereType<String>() ??
              const <String>[])
        ManifestExtraProp(name: name, isRequired: required.contains(name)),
    ];
  }

  /// Whether the catalog can be asked with nothing chosen: no property of
  /// it is required. What puts a catalog on the board, as a row.
  bool get needsNoInput => !extraProps.any((prop) => prop.isRequired);

  /// The extra that opens the catalog: each required property at its
  /// first option. Null when a required property has no options -- a
  /// search-only catalog -- which nothing but a search can open.
  /// stremio-core's `default_required_extra`, which decides what Discover
  /// offers.
  List<ExtraValue>? get defaultRequiredExtra {
    final extra = <ExtraValue>[];
    for (final prop in extraProps.where((prop) => prop.isRequired)) {
      if (prop.options.isEmpty) return null;
      extra.add(ExtraValue(prop.name, prop.options.first));
    }
    return extra;
  }

  static List<ManifestCatalog> listFromJson(Object? json) => [
    for (final item in (json as List<dynamic>? ?? const []))
      ManifestCatalog(item as Map<String, dynamic>),
  ];
}

/// One extra property of a [ManifestCatalog].
final class ManifestExtraProp {
  const ManifestExtraProp({
    required this.name,
    this.isRequired = false,
    this.options = const [],
  });

  final String name;
  final bool isRequired;
  final List<String> options;
}

/// `Manifest.behaviorHints`; every flag defaults to false.
final class ManifestBehaviorHints {
  const ManifestBehaviorHints(this.json);

  final Map<String, dynamic> json;

  /// Has a `/configure` page.
  bool get configurable => json['configurable'] as bool? ?? false;

  /// Must be configured before it can be installed (`InstallAddon` fails
  /// with `Other` code 6): the manifest URL is a template, not an addon.
  bool get configurationRequired =>
      json['configurationRequired'] as bool? ?? false;
}
