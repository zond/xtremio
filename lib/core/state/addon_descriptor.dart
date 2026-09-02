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
  /// `manifest.json` replaced by `configure`, as the official clients open
  /// it. Null when the manifest declares neither `configurable` nor
  /// `configurationRequired`.
  String? get configureUrl {
    final hints = manifest.behaviorHints;
    if (!hints.configurable && !hints.configurationRequired) return null;
    return transportUrl.replaceFirst(RegExp(r'manifest\.json$'), 'configure');
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
  String get name => json['name'] as String? ?? '';
  String? get description => json['description'] as String?;
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

  static List<ManifestCatalog> listFromJson(Object? json) => [
    for (final item in (json as List<dynamic>? ?? const []))
      ManifestCatalog(item as Map<String, dynamic>),
  ];
}

/// `Manifest.behaviorHints`; every flag defaults to false.
final class ManifestBehaviorHints {
  const ManifestBehaviorHints(this.json);

  final Map<String, dynamic> json;

  bool get adult => json['adult'] as bool? ?? false;
  bool get p2p => json['p2p'] as bool? ?? false;

  /// Has a `/configure` page.
  bool get configurable => json['configurable'] as bool? ?? false;

  /// Must be configured before it can be installed (`InstallAddon` fails
  /// with `Other` code 6): the manifest URL is a template, not an addon.
  bool get configurationRequired =>
      json['configurationRequired'] as bool? ?? false;
}
