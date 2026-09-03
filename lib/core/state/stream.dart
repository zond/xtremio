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

  Map<String, dynamic> get behaviorHints =>
      json['behaviorHints'] as Map<String, dynamic>? ?? const {};

  /// `behaviorHints.filename`: the file the addon expects to play, when it
  /// says so (used for subtitle lookups and as a tooltip).
  String? get filename => behaviorHints['filename'] as String?;

  /// Subtitle files the addon attached to the stream itself (raw
  /// `Subtitles` JSON; `lib/core/state/player.dart` types them).
  List<Map<String, dynamic>> get subtitlesJson => [
    for (final item in (json['subtitles'] as List<dynamic>? ?? const []))
      item as Map<String, dynamic>,
  ];

  /// Two streams point at the same source when their discriminating keys
  /// match (`Stream::is_source_match`, minus the archive variants).
  bool isSameSource(StreamInfo other) {
    if (infoHash != null || other.infoHash != null) {
      return infoHash == other.infoHash && fileIdx == other.fileIdx;
    }
    if (url != null || other.url != null) return url == other.url;
    if (ytId != null || other.ytId != null) return ytId == other.ytId;
    if (externalUrl != null || other.externalUrl != null) {
      return externalUrl == other.externalUrl;
    }
    return false;
  }

  /// [isSameSource] as a value that can be put in a map: the same
  /// discriminating keys, joined. Null when the source has none of them
  /// (an unknown variant), which is what [isSameSource] answers false for
  /// -- so a stream with no key is never folded into another one.
  ///
  /// The info hash is lower-cased: stremio-core serializes it from the 20
  /// bytes it parsed, so it already is, but a hand-written stream (a
  /// developer fixture, an offline entry) need not be, and two spellings
  /// of one hash are one torrent.
  String? get sourceKey {
    final infoHash = this.infoHash;
    if (infoHash != null) {
      return 'torrent:${infoHash.toLowerCase()}/$fileIdx';
    }
    final url = this.url;
    if (url != null) return 'url:$url';
    final ytId = this.ytId;
    if (ytId != null) return 'yt:$ytId';
    final externalUrl = this.externalUrl;
    if (externalUrl != null) return 'external:$externalUrl';
    return null;
  }

  /// The trackers the addon named for a torrent.
  ///
  /// `announce` is stremio-core's field; `sources` is the addon protocol's
  /// own name for the same list, which the engine reads as an alias. Which
  /// one is consulted mirrors the Rust side's `string_list`: the first key
  /// that is an array wins, never both concatenated.
  List<String> get trackers {
    for (final key in const ['announce', 'sources']) {
      final list = json[key];
      if (list is List) return [...list.whereType<String>()];
    }
    return const [];
  }

  /// [this] with [trackers] as the trackers it carries, for a torrent that
  /// several addons listed with different `announce` sets: the union is
  /// what the server should be given, since every entry is a place the
  /// swarm may answer from.
  ///
  /// Returns [this] unchanged when there is nothing to add, and for a
  /// source that has no trackers at all (only a torrent does).
  StreamInfo withTrackers(List<String> trackers) {
    if (kind != StreamKind.torrent) return this;
    final own = this.trackers;
    if (own.length == trackers.length) {
      var same = true;
      for (var i = 0; i < own.length; i++) {
        if (own[i] != trackers[i]) {
          same = false;
          break;
        }
      }
      if (same) return this;
    }
    final merged = {...json, 'announce': trackers};
    // `sources` says the same thing under the protocol's name, and
    // stremio-core reads it as an alias of `announce` -- both keys at once
    // is a duplicate field to it. The merged list replaces the pair.
    merged.remove('sources');
    return StreamInfo(merged);
  }

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
