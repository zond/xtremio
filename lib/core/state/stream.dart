/// View over stremio-core's `Stream` JSON (a flattened `StreamSource` plus
/// name/description/behaviorHints). The raw map is kept because it is what
/// `Load Player` takes back.
final class StreamInfo {
  const StreamInfo(this.json);

  final Map<String, dynamic> json;

  String? get name => json['name'] as String?;

  /// `description`, or the legacy `title` older addons still send.
  String? get description =>
      json['description'] as String? ?? json['title'] as String?;

  String? get infoHash => json['infoHash'] as String?;
  int? get fileIdx => json['fileIdx'] as int?;
  String? get url => json['url'] as String?;
  String? get ytId => json['ytId'] as String?;
  String? get externalUrl => json['externalUrl'] as String?;

  /// Which `StreamSource` variant this is, by the discriminating key.
  StreamKind get kind {
    if (infoHash != null) return StreamKind.torrent;
    final url = this.url;
    if (url != null) {
      return url.startsWith('magnet:') ? StreamKind.magnet : StreamKind.url;
    }
    if (ytId != null) return StreamKind.youtube;
    if (externalUrl != null || json['androidTvUrl'] != null) {
      return StreamKind.external;
    }
    if (json['playerFrameUrl'] != null) return StreamKind.playerFrame;
    if (json.keys.any((key) => key.endsWith('Urls') || key == 'nzbUrl')) {
      return StreamKind.archive;
    }
    return StreamKind.unknown;
  }

  /// Whether the core's `Player` model can turn this into something libmpv
  /// plays: direct URLs, and everything the streaming server resolves.
  bool get isPlayable => switch (kind) {
    StreamKind.url ||
    StreamKind.torrent ||
    StreamKind.youtube ||
    StreamKind.archive => true,
    StreamKind.magnet ||
    StreamKind.external ||
    StreamKind.playerFrame ||
    StreamKind.unknown => false,
  };

  /// One line for a list tile.
  String get title => name ?? description ?? kind.label;

  static List<StreamInfo> listFromJson(Object? json) => [
    for (final item in (json as List<dynamic>? ?? const []))
      StreamInfo(item as Map<String, dynamic>),
  ];
}

enum StreamKind {
  /// `url`: played directly (or proxied when `proxyHeaders` are set).
  url('Direct'),

  /// `url` with a `magnet:` scheme; the core leaves these unresolved.
  magnet('Magnet'),

  /// `infoHash` (+ `fileIdx`, `announce`): served by the streaming server.
  torrent('Torrent'),
  youtube('YouTube'),

  /// `externalUrl` / `androidTvUrl` / ...: opens another app or site.
  external('External'),
  playerFrame('Embedded player'),

  /// `rarUrls`, `zipUrls`, ...: extracted by the streaming server.
  archive('Archive'),
  unknown('Unknown');

  const StreamKind(this.label);

  final String label;
}
