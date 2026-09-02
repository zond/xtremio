import 'dart:convert';
import 'dart:io';

/// Where a torrent is in its start-up, as the embedded stream-server reports
/// it in `stats.json` (`phase`).
enum TorrentPhase {
  /// A magnet still resolving its info dictionary: no files, no pieces.
  resolvingMetadata('resolvingMetadata'),

  /// Metadata known; data already on disk is being hash-checked
  /// (`checkedBytes` / `checkTotalBytes`).
  checking('checking'),

  /// Live, but the head of the stream file (its initial priority window)
  /// is not fully on disk yet (`initialWindowReadyBytes` /
  /// `initialWindowBytes`).
  buffering('buffering'),

  /// The initial window is on disk: playback can start without stalling.
  ready('ready'),

  /// The torrent engine gave up on this torrent.
  error('error'),

  /// A phase this client does not know (a newer server).
  unknown('');

  const TorrentPhase(this.wireName);

  final String wireName;

  static TorrentPhase parse(Object? value) => TorrentPhase.values.firstWhere(
    (phase) => phase != unknown && phase.wireName == value,
    orElse: () => unknown,
  );
}

/// The server's peer-discovery counters (`peerDiscovery`): how far the
/// swarm search has come while nothing is downloading yet.
final class PeerDiscovery {
  const PeerDiscovery({
    this.seen = 0,
    this.queued = 0,
    this.connecting = 0,
    this.live = 0,
  });

  /// Distinct peer addresses learned from DHT, trackers and PEX so far.
  final int seen;

  /// Known peers waiting for a connection slot.
  final int queued;

  /// Outgoing connections being established.
  final int connecting;

  /// Peers with a completed handshake.
  final int live;

  factory PeerDiscovery.fromJson(Map<String, dynamic> json) => PeerDiscovery(
    seen: _int(json['seen']),
    queued: _int(json['queued']),
    connecting: _int(json['connecting']),
    live: _int(json['live']),
  );

  @override
  bool operator ==(Object other) =>
      other is PeerDiscovery &&
      other.seen == seen &&
      other.queued == queued &&
      other.connecting == connecting &&
      other.live == live;

  @override
  int get hashCode => Object.hash(seen, queued, connecting, live);
}

/// The slice of stream-server's per-torrent `stats.json` the pre-playback
/// overlay shows. The response keeps the server.js-compatible shape
/// stremio-core parses and adds the camelCase phase fields.
final class TorrentStats {
  const TorrentStats({
    required this.phase,
    this.checkedBytes,
    this.checkTotalBytes,
    this.initialWindowReadyBytes,
    this.initialWindowBytes,
    this.peerDiscovery = const PeerDiscovery(),
    this.downloadSpeed = 0,
    this.peers = 0,
  });

  final TorrentPhase phase;

  /// Hash-check progress; non-null only while [TorrentPhase.checking].
  final int? checkedBytes;
  final int? checkTotalBytes;

  /// Bytes of the stream file's head window verified on disk, and the
  /// window's size (`min(4 MiB, file length)`); non-null only in
  /// [TorrentPhase.buffering] / [TorrentPhase.ready].
  final int? initialWindowReadyBytes;
  final int? initialWindowBytes;

  final PeerDiscovery peerDiscovery;

  /// Bytes per second (`downloadSpeed`).
  final double downloadSpeed;

  /// Connected peers (`peers`).
  final int peers;

  factory TorrentStats.fromJson(Map<String, dynamic> json) {
    final discovery = json['peerDiscovery'];
    return TorrentStats(
      phase: TorrentPhase.parse(json['phase']),
      checkedBytes: _intOrNull(json['checkedBytes']),
      checkTotalBytes: _intOrNull(json['checkTotalBytes']),
      initialWindowReadyBytes: _intOrNull(json['initialWindowReadyBytes']),
      initialWindowBytes: _intOrNull(json['initialWindowBytes']),
      peerDiscovery: discovery is Map<String, dynamic>
          ? PeerDiscovery.fromJson(discovery)
          : const PeerDiscovery(),
      downloadSpeed: (json['downloadSpeed'] as num?)?.toDouble() ?? 0,
      peers: _int(json['peers']),
    );
  }

  /// `0..1` of the hash check, when the server reports one.
  double? get checkProgress => _ratio(checkedBytes, checkTotalBytes);

  /// `0..1` of the initial window, when the server reports one.
  double? get initialWindowProgress =>
      _ratio(initialWindowReadyBytes, initialWindowBytes);

  static double? _ratio(int? part, int? total) {
    if (part == null || total == null || total <= 0) return null;
    return (part / total).clamp(0, 1).toDouble();
  }

  /// The `stats.json` for a stream the embedded server serves: the core's
  /// `<server>/{infoHash}/{fileIdx}?tr=…` becomes
  /// `<server>/{infoHash}/{fileIdx}/stats.json` (or `/{infoHash}/stats.json`
  /// when no file index is in the path, e.g. `-1`, the server's guess).
  /// Null when [streamingUrl] is not such a URL (a direct HTTP stream).
  static Uri? statsUrlFor(Uri streamingUrl) {
    final segments = streamingUrl.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty || !_infoHash.hasMatch(segments.first)) return null;
    final fileIdx = segments.length > 1 ? int.tryParse(segments[1]) : null;
    return Uri(
      scheme: streamingUrl.scheme,
      host: streamingUrl.host,
      port: streamingUrl.hasPort ? streamingUrl.port : null,
      pathSegments: [
        segments.first,
        if (fileIdx != null && fileIdx >= 0) '$fileIdx',
        'stats.json',
      ],
    );
  }

  static final RegExp _infoHash = RegExp(r'^[0-9a-fA-F]{40}$');

  @override
  bool operator ==(Object other) =>
      other is TorrentStats &&
      other.phase == phase &&
      other.checkedBytes == checkedBytes &&
      other.checkTotalBytes == checkTotalBytes &&
      other.initialWindowReadyBytes == initialWindowReadyBytes &&
      other.initialWindowBytes == initialWindowBytes &&
      other.peerDiscovery == peerDiscovery &&
      other.downloadSpeed == downloadSpeed &&
      other.peers == peers;

  @override
  int get hashCode => Object.hash(
    phase,
    checkedBytes,
    checkTotalBytes,
    initialWindowReadyBytes,
    initialWindowBytes,
    peerDiscovery,
    downloadSpeed,
    peers,
  );
}

int _int(Object? value) => (value as num?)?.toInt() ?? 0;
int? _intOrNull(Object? value) => (value as num?)?.toInt();

/// Fetches a torrent's `stats.json` from the embedded server. The player
/// polls it while a torrent starts up; widget tests substitute a fake
/// through `PlaybackScope`.
abstract interface class TorrentStatsClient {
  /// The stats at [statsUrl], or null when the server has nothing to say
  /// yet: not reachable, a non-200 answer (404), or a body that is not the
  /// expected JSON.
  Future<TorrentStats?> fetch(Uri statsUrl);
}

/// [TorrentStatsClient] over `dart:io`, like the rest of the Dart side's
/// loopback traffic to the server. Never throws: every failure is "no
/// stats yet".
class HttpTorrentStatsClient implements TorrentStatsClient {
  const HttpTorrentStatsClient();

  /// Short: the server is on loopback, and a poll that overruns the next
  /// tick is worth less than the next tick.
  static const Duration timeout = Duration(seconds: 2);

  @override
  Future<TorrentStats?> fetch(Uri statsUrl) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(statsUrl).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final json = jsonDecode(body);
      return json is Map<String, dynamic> ? TorrentStats.fromJson(json) : null;
    } on Exception {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
