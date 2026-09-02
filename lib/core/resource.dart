/// Addon resource addressing, mirroring stremio-core's `ResourcePath`,
/// `ResourceRequest` and `ExtraValue` JSON shapes.
library;

/// Cinemeta, the default metadata addon.
const String kCinemetaManifestUrl =
    'https://v3-cinemeta.strem.io/manifest.json';

/// One `name=value` extra of a catalog request. Serialized as a two-element
/// array, exactly like stremio-core's `ExtraValue`.
final class ExtraValue {
  const ExtraValue(this.name, this.value);

  final String name;
  final String value;

  factory ExtraValue.fromJson(Object? json) {
    final list = json as List<dynamic>;
    return ExtraValue(list[0] as String, list[1] as String);
  }

  List<String> toJson() => [name, value];

  @override
  bool operator ==(Object other) =>
      other is ExtraValue && other.name == name && other.value == value;

  @override
  int get hashCode => Object.hash(name, value);
}

/// `{resource}/{type}/{id}` plus extras, e.g. `catalog/movie/top`.
final class ResourcePath {
  const ResourcePath({
    required this.resource,
    required this.type,
    required this.id,
    this.extra = const [],
  });

  final String resource;
  final String type;
  final String id;
  final List<ExtraValue> extra;

  factory ResourcePath.fromJson(Map<String, dynamic> json) => ResourcePath(
    resource: json['resource'] as String,
    type: json['type'] as String,
    id: json['id'] as String,
    extra: [
      for (final value in (json['extra'] as List<dynamic>? ?? const []))
        ExtraValue.fromJson(value),
    ],
  );

  Map<String, dynamic> toJson() => {
    'resource': resource,
    'type': type,
    'id': id,
    'extra': [for (final value in extra) value.toJson()],
  };

  /// The same resource for another item (the next episode, say).
  ResourcePath copyWith({String? id}) => ResourcePath(
    resource: resource,
    type: type,
    id: id ?? this.id,
    extra: extra,
  );
}

/// A resource path addressed to one addon (its manifest URL).
final class ResourceRequest {
  const ResourceRequest({required this.base, required this.path});

  /// Catalog `id` of `type` from Cinemeta (e.g. `movie` / `top`).
  factory ResourceRequest.cinemetaCatalog({
    required String type,
    required String id,
    List<ExtraValue> extra = const [],
  }) => ResourceRequest(
    base: kCinemetaManifestUrl,
    path: ResourcePath(resource: 'catalog', type: type, id: id, extra: extra),
  );

  /// Addon manifest URL.
  final String base;
  final ResourcePath path;

  factory ResourceRequest.fromJson(Map<String, dynamic> json) =>
      ResourceRequest(
        base: json['base'] as String,
        path: ResourcePath.fromJson(json['path'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {'base': base, 'path': path.toJson()};

  ResourceRequest copyWith({ResourcePath? path}) =>
      ResourceRequest(base: base, path: path ?? this.path);
}
