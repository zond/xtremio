/// What the mainline DHT looks like on this host right now, as the
/// embedded server sees it (`ServerHandle::dht_status`/the `dht` key of
/// `GET /stats.json`).
///
/// The DHT is a peer *source*, not a requirement: a torrent with working
/// trackers downloads fine without one. A network that drops the UDP the
/// DHT needs -- carrier-grade NAT, a firewalled mobile APN, a captive
/// portal -- simply never finishes bootstrapping, for the whole session,
/// with nothing actually wrong: on the owner's own phone torrents ran at
/// 30+ MB/s from trackers alone while the DHT never came up once. That is
/// why this is information, never an error: nothing here is worth a toast,
/// and nothing should poll it expecting a quick flip -- read it when a
/// screen opens, or piggyback it on a poll that is already running.
class DhtStatus {
  const DhtStatus({
    required this.enabled,
    required this.nodes,
    required this.nodesV6,
    required this.everBootstrapped,
  });

  factory DhtStatus.fromJson(Map<String, dynamic> json) => DhtStatus(
    enabled: json['enabled'] as bool? ?? false,
    nodes: (json['nodes'] as num?)?.toInt() ?? 0,
    nodesV6: (json['nodesV6'] as num?)?.toInt() ?? 0,
    everBootstrapped: json['everBootstrapped'] as bool? ?? false,
  );

  /// Whether a DHT is running at all (false when the server's backend was
  /// built with none, or when the server is not running -- both answer "no
  /// DHT to ask" the same way).
  final bool enabled;

  /// Nodes in the IPv4 routing table right now.
  final int nodes;

  /// Nodes in the IPv6 routing table right now.
  final int nodesV6;

  /// Whether either routing table has *ever* been non-empty this session.
  /// Sticky: a table that empties out again (peers aged out, the network
  /// changed) still counts as having bootstrapped once, which is the
  /// difference between "the DHT is idle" and "the DHT never worked here".
  final bool everBootstrapped;

  /// A DHT that is running but has never found a single node this session
  /// -- the one state worth telling a curious person about. Never an
  /// error: trackers alone regularly outrun a DHT swarm, and a bootstrapped
  /// or disabled DHT says nothing here at all.
  bool get unavailable => enabled && !everBootstrapped;

  /// The line to show wherever [unavailable] is worth saying.
  static const String unavailableMessage =
      'DHT unavailable — using trackers only';

  /// `0 nodes (0 v6)`: the raw counts, for a details view a curious person
  /// opens on purpose -- never shown alongside [unavailableMessage] by
  /// default.
  String get nodeCounts => '$nodes nodes ($nodesV6 v6)';

  @override
  bool operator ==(Object other) =>
      other is DhtStatus &&
      other.enabled == enabled &&
      other.nodes == nodes &&
      other.nodesV6 == nodesV6 &&
      other.everBootstrapped == everBootstrapped;

  @override
  int get hashCode => Object.hash(enabled, nodes, nodesV6, everBootstrapped);

  @override
  String toString() =>
      'DhtStatus(enabled: $enabled, nodes: $nodes, nodesV6: $nodesV6, '
      'everBootstrapped: $everBootstrapped)';
}
