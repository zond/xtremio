/// What order the streams inside one resolution section are listed in.
///
/// **Why the default is peers per megabyte.** Every stream in the list is
/// the same film, so its duration is a constant and its size is
/// proportional to its bitrate. Bitrate is the demand the connection has to
/// meet; peers are the supply that meets it. The smallest size *per peer*
/// is therefore the best first guess at a stream that arrives faster than
/// it is watched — which is the thing that usually goes wrong — and it is a
/// better guess than either half on its own: the fattest remux with a
/// hundred seeders can still stall, and a lonely 700 MB rip can still
/// arrive in time.
///
/// It stays a guess. Peers are a convention read out of a description
/// ([StreamFacts.seeders]) rather than a field of any protocol, and how
/// fast a swarm actually serves is not in the list at all. So the other two
/// orders are here for when the guess is wrong: the largest file when
/// quality is what matters and the connection is not in question, and the
/// most peers when nothing is arriving at all.
library;

enum StreamOrder {
  /// Ascending size ÷ peers: the most peers per megabyte first. The
  /// default, and the reason this enum exists.
  peersPerSize,

  /// Largest file first.
  largest,

  /// Most peers first.
  mostPeers;

  /// What the choice is stored as (`AppPrefs.streamsOrderKey`).
  String get stored => name;

  /// The chip that selects it.
  String get label => switch (this) {
    StreamOrder.peersPerSize => 'Peers per MB',
    StreamOrder.largest => 'Largest first',
    StreamOrder.mostPeers => 'Most peers',
  };

  /// The stored spelling back to a choice; null for anything else,
  /// including a name a newer build wrote, so an unknown value reads as
  /// "not set" and the default stands.
  static StreamOrder? parse(Object? stored) {
    if (stored is! String) return null;
    for (final order in StreamOrder.values) {
      if (order.stored == stored) return order;
    }
    return null;
  }
}
