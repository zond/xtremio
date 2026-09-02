/// View over stremio-core's `MetaItemPreview` JSON as it appears in
/// catalog pages. Only what the grids need; the raw map stays reachable.
/// `MetaItem` extends it with the full-item fields.
class MetaItemPreview {
  const MetaItemPreview(this.json);

  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get type => json['type'] as String;
  String get name => json['name'] as String? ?? '';
  String? get poster => json['poster'] as String?;
  String? get background => json['background'] as String?;
  String? get description => json['description'] as String?;
  String? get releaseInfo => json['releaseInfo'] as String?;

  /// `poster` | `landscape` | `square`.
  String get posterShape => json['posterShape'] as String? ?? 'poster';

  static List<MetaItemPreview> listFromJson(Object? json) => [
    for (final item in (json as List<dynamic>? ?? const []))
      MetaItemPreview(item as Map<String, dynamic>),
  ];
}
