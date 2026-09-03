import '../../core/core.dart';

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

/// Byte progress of the single piece the open reader is sitting on
/// (`inFlightPiece`): the finer view of the one piece that decides when
/// playback can go on.
///
/// A piece is the unit that becomes readable -- none of a 16 MiB piece can
/// be served until all 16 MiB of it verifies -- so the have-bitfield the
/// window is measured against is too coarse to show a waiting player
/// anything but 0 or 100. This is the number that moves in between.
///
/// The whole object is null when the server does not know: no reader open
/// on that file, no metadata yet, or a torrent with no chunk map. Null is
/// "we do not know", never "nothing downloaded" -- the server sends null
/// rather than a zeroed object precisely so the two stay apart.
final class InFlightPiece {
  const InFlightPiece({
    required this.index,
    required this.downloadedBytes,
    required this.totalBytes,
    this.verified = false,
  });

  /// The piece's index **in the torrent**, not in the file.
  final int index;

  /// Bytes of it written to disk. **This can go backwards**: a chunk
  /// counts the moment it is written, the hash is only checked once every
  /// chunk is in, and a piece that fails the check is discarded and drops
  /// back to zero. See [verified].
  final int downloadedBytes;

  /// The piece's own length: [TorrentStats.pieceLength] for every piece
  /// but the torrent's last, which is short. The server clamps it, so
  /// nothing here multiplies anything itself.
  final int totalBytes;

  /// Whether the piece is in the have-bitfield and can be served. A full
  /// [downloadedBytes] on its own only means "complete enough to be
  /// hashed"; this is the only field that means ready.
  final bool verified;

  /// The server's own measure, `0..1`. It is bytes on disk, not bytes that
  /// can be served -- what shows it has to hold short of full until
  /// [verified] (see `PieceProgressBar`).
  double get progress => (downloadedBytes / totalBytes).clamp(0, 1).toDouble();

  /// The object for an `inFlightPiece` value, or null for the null the
  /// server sends when it does not know -- and for anything malformed,
  /// which is the same not-knowing.
  static InFlightPiece? fromJson(Object? value) {
    if (value is! Map) return null;
    final index = _intOrNull(value['index']);
    final total = _intOrNull(value['totalBytes']);
    if (index == null || total == null || total <= 0) return null;
    return InFlightPiece(
      index: index,
      downloadedBytes: (_intOrNull(value['downloadedBytes']) ?? 0).clamp(
        0,
        total,
      ),
      totalBytes: total,
      verified: value['verified'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is InFlightPiece &&
      other.index == index &&
      other.downloadedBytes == downloadedBytes &&
      other.totalBytes == totalBytes &&
      other.verified == verified;

  @override
  int get hashCode => Object.hash(index, downloadedBytes, totalBytes, verified);

  @override
  String toString() =>
      'InFlightPiece(#$index, $downloadedBytes/$totalBytes, '
      'verified: $verified)';
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
    this.pieceLength,
    this.inFlightPiece,
    this.peerDiscovery = const PeerDiscovery(),
    this.downloadSpeed = 0,
    this.peers = 0,
    this.connectedSeeders = 0,
    this.swarmSeeders,
    this.swarmLeechers,
    this.swarmScrapeAge,
    this.error,
  });

  final TorrentPhase phase;

  /// Hash-check progress; non-null only while [TorrentPhase.checking].
  final int? checkedBytes;
  final int? checkTotalBytes;

  /// Bytes of the window the reader is waiting for that are verified on
  /// disk, and the window's size; non-null only in
  /// [TorrentPhase.buffering] / [TorrentPhase.ready].
  ///
  /// The window is piece-aligned and follows the reader, so after a seek
  /// or a re-open it describes the bytes actually being fetched rather
  /// than the head of the file. Equal values mean exactly "servable".
  final int? initialWindowReadyBytes;
  final int? initialWindowBytes;

  /// The torrent's piece length (`pieceLength`), null until its metadata
  /// resolves.
  ///
  /// A piece is the unit that becomes readable: librqbit credits verified
  /// pieces and nothing in between, so a window one piece wide can only
  /// ever read 0 or all of it. On a multi-gigabyte torrent a piece is
  /// 8-16 MiB, which is why a percentage sat at 0% for tens of seconds
  /// while the download was running perfectly. What shows a wait has to
  /// say it in pieces when there is only one of them; see
  /// [windowPieces] and [initialWindowProgress].
  final int? pieceLength;

  /// How far the one piece the reader is sitting on has come
  /// (`inFlightPiece`), or null when the server does not know -- which is
  /// not the same as zero; see [InFlightPiece].
  ///
  /// This is what turns "waiting for the first piece (16 MiB)" into
  /// "waiting for piece 137, 6.3 of 16.0 MiB" and gives the bar something
  /// to draw.
  final InFlightPiece? inFlightPiece;

  final PeerDiscovery peerDiscovery;

  /// Bytes per second (`downloadSpeed`).
  final double downloadSpeed;

  /// Connected peers (`peers`).
  final int peers;

  /// How many of [peers] hold the whole torrent, i.e. can serve any piece
  /// (`connectedSeeders`). Never more than [peers]: it counts our own
  /// connections, not the swarm -- for the swarm read [swarmSeeders].
  final int connectedSeeders;

  /// Seeders in the whole swarm as the torrent's trackers report them
  /// (`swarmSeeders`), or null when we could not ask: a torrent with no
  /// trackers, a private one, or trackers that have not answered.
  ///
  /// Null is not zero. The server never sends 0 for "unknown" precisely
  /// because a swarm with nobody seeding is a real and different state, so
  /// nothing here may turn a null into a 0 either, and what shows it must
  /// keep the two apart.
  final int? swarmSeeders;

  /// Leechers in the whole swarm (`swarmLeechers`); null under the same
  /// rules as [swarmSeeders].
  final int? swarmLeechers;

  /// How long ago the freshest tracker scrape behind [swarmSeeders] and
  /// [swarmLeechers] came back (`swarmScrapeAgeSecs`), so a display can say
  /// how current they are: they are a snapshot, not a measurement. Null
  /// exactly when those two are.
  final Duration? swarmScrapeAge;

  /// Why the phase is [TorrentPhase.error], when the server says (`error`:
  /// a magnet whose add timed out or failed); null otherwise.
  final String? error;

  factory TorrentStats.fromJson(Map<String, dynamic> json) {
    final discovery = json['peerDiscovery'];
    return TorrentStats(
      phase: TorrentPhase.parse(json['phase']),
      checkedBytes: _intOrNull(json['checkedBytes']),
      checkTotalBytes: _intOrNull(json['checkTotalBytes']),
      initialWindowReadyBytes: _intOrNull(json['initialWindowReadyBytes']),
      initialWindowBytes: _intOrNull(json['initialWindowBytes']),
      pieceLength: _intOrNull(json['pieceLength']),
      inFlightPiece: InFlightPiece.fromJson(json['inFlightPiece']),
      peerDiscovery: discovery is Map<String, dynamic>
          ? PeerDiscovery.fromJson(discovery)
          : const PeerDiscovery(),
      downloadSpeed: (json['downloadSpeed'] as num?)?.toDouble() ?? 0,
      peers: _int(json['peers']),
      connectedSeeders: _int(json['connectedSeeders']),
      swarmSeeders: _intOrNull(json['swarmSeeders']),
      swarmLeechers: _intOrNull(json['swarmLeechers']),
      swarmScrapeAge: switch (_intOrNull(json['swarmScrapeAgeSecs'])) {
        final seconds? => Duration(seconds: seconds),
        null => null,
      },
      error: json['error'] as String?,
    );
  }

  /// `0..1` of the hash check, when the server reports one.
  double? get checkProgress => _ratio(checkedBytes, checkTotalBytes);

  /// How many pieces the window the reader waits for spans, when both it
  /// and the piece length are known.
  ///
  /// The window is piece-aligned, so this is an exact count rather than an
  /// estimate. 1 means the whole wait is one piece arriving: there is no
  /// progress to show between 0 and done, and pretending otherwise is what
  /// made a working download look stuck.
  int? get windowPieces {
    final window = initialWindowBytes;
    final piece = pieceLength;
    if (window == null || piece == null || piece <= 0 || window <= 0) {
      return null;
    }
    return (window / piece).ceil();
  }

  /// Whether the wait is a single piece, so it must be described rather
  /// than measured. False when the window spans several pieces (a
  /// percentage then really does advance) and false when the piece length
  /// is unknown, where a percentage is the best that can be said.
  bool get waitsForOnePiece => windowPieces == 1;

  /// `0..1` of the window the reader waits for -- null when there is
  /// nothing honest to show, which now includes a window one piece wide:
  /// it can only ever be 0 or 1, and a bar that jumps between the two is a
  /// worse answer than a sentence.
  double? get initialWindowProgress => waitsForOnePiece
      ? null
      : _ratio(initialWindowReadyBytes, initialWindowBytes);

  /// How long the piece being waited for should take at the current
  /// download speed, when both are known and moving. An estimate, and
  /// named as one wherever it is shown.
  ///
  /// When the wait is one piece and the server says how far *into* that
  /// piece it is, the remainder is the piece's -- which shrinks between
  /// polls. The window's own bytes only move when a whole piece verifies,
  /// so on their own they would hold the same estimate for the entire
  /// wait.
  Duration? get windowEta {
    if (downloadSpeed <= 0) return null;
    final piece = inFlightPiece;
    final int remaining;
    if (waitsForOnePiece && piece != null) {
      remaining = piece.totalBytes - piece.downloadedBytes;
    } else {
      final window = initialWindowBytes;
      if (window == null) return null;
      remaining = window - (initialWindowReadyBytes ?? 0);
    }
    if (remaining <= 0) return null;
    final seconds = remaining / downloadSpeed;
    if (!seconds.isFinite || seconds > 3600) return null;
    return Duration(seconds: seconds.ceil());
  }

  static double? _ratio(int? part, int? total) {
    if (part == null || total == null || total <= 0) return null;
    return (part / total).clamp(0, 1).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      other is TorrentStats &&
      other.phase == phase &&
      other.checkedBytes == checkedBytes &&
      other.checkTotalBytes == checkTotalBytes &&
      other.initialWindowReadyBytes == initialWindowReadyBytes &&
      other.initialWindowBytes == initialWindowBytes &&
      other.pieceLength == pieceLength &&
      other.inFlightPiece == inFlightPiece &&
      other.peerDiscovery == peerDiscovery &&
      other.downloadSpeed == downloadSpeed &&
      other.peers == peers &&
      other.connectedSeeders == connectedSeeders &&
      other.swarmSeeders == swarmSeeders &&
      other.swarmLeechers == swarmLeechers &&
      other.swarmScrapeAge == swarmScrapeAge &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    phase,
    checkedBytes,
    checkTotalBytes,
    initialWindowReadyBytes,
    initialWindowBytes,
    pieceLength,
    inFlightPiece,
    peerDiscovery,
    downloadSpeed,
    peers,
    connectedSeeders,
    swarmSeeders,
    swarmLeechers,
    swarmScrapeAge,
    error,
  );
}

int _int(Object? value) => (value as num?)?.toInt() ?? 0;
int? _intOrNull(Object? value) => (value as num?)?.toInt();

/// Which torrent's stats to ask the embedded server for: what the server's
/// `/{infoHash}/{fileIdx}/stats.json?tr=…` route takes, minus the HTTP.
/// The core builds the stream URL from the same three things
/// (`infoHash`, `fileIdx`, `announce` → `tr=`), so the stats describe the
/// torrent the player is opening.
final class TorrentStatsRequest {
  const TorrentStatsRequest({
    required this.infoHash,
    this.fileIdx,
    this.trackers = const [],
  });

  final String infoHash;

  /// The file within the torrent, or null for the torrent as a whole (the
  /// stream had no `fileIdx`; the server picks the largest file, and the
  /// core's URL carries `-1`).
  final int? fileIdx;

  /// The stream's `announce` list, passed on as is: the server needs the
  /// trackers only when a stats request is what creates the engine.
  final List<String> trackers;

  /// The request for [stream], or null when it is not a torrent (nothing to
  /// ask the server about a direct HTTP stream). A negative `fileIdx` means
  /// none.
  static TorrentStatsRequest? forStream(StreamInfo? stream) {
    final infoHash = stream?.infoHash;
    if (stream == null || infoHash == null) return null;
    final fileIdx = stream.fileIdx;
    return TorrentStatsRequest(
      infoHash: infoHash,
      fileIdx: fileIdx == null || fileIdx < 0 ? null : fileIdx,
      trackers: [
        for (final tracker
            in (stream.json['announce'] as List<dynamic>? ?? const []))
          if (tracker is String) tracker,
      ],
    );
  }

  /// The same torrent without the file: the torrent-level stats.
  TorrentStatsRequest get torrentLevel => fileIdx == null
      ? this
      : TorrentStatsRequest(infoHash: infoHash, trackers: trackers);

  @override
  bool operator ==(Object other) =>
      other is TorrentStatsRequest &&
      other.infoHash == infoHash &&
      other.fileIdx == fileIdx &&
      other.trackers.length == trackers.length &&
      Iterable.generate(trackers.length)
          .every((i) => other.trackers[i] == trackers[i]);

  @override
  int get hashCode => Object.hash(infoHash, fileIdx, Object.hashAll(trackers));

  @override
  String toString() =>
      'TorrentStatsRequest($infoHash, fileIdx: $fileIdx, trackers: $trackers)';
}

/// Fetches a torrent's `stats.json` from the embedded server. The player
/// polls it while a torrent starts up; widget tests substitute a fake
/// through `PlaybackScope`.
abstract interface class TorrentStatsClient {
  /// The stats for [request], or null when the server has nothing to say:
  /// not running, an index the torrent does not have, or an answer that is
  /// not the expected JSON.
  Future<TorrentStats?> fetch(TorrentStatsRequest request);
}

/// [TorrentStatsClient] over the embedded server's library API (FFI): the
/// same function its `stats.json` routes run, without HTTP or the bearer
/// token those routes require. Never throws: every failure is "no stats".
class RustTorrentStatsClient implements TorrentStatsClient {
  const RustTorrentStatsClient({this.server = const ServerClient()});

  final ServerClient server;

  @override
  Future<TorrentStats?> fetch(TorrentStatsRequest request) async {
    try {
      final json = await server.torrentStats(
        infoHash: request.infoHash,
        fileIdx: request.fileIdx,
        trackers: request.trackers,
      );
      return TorrentStats.fromJson(json);
    } on Object {
      return null;
    }
  }
}
