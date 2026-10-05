/// Whether mpv's reader of a media id is waiting on a read right now
/// (stream-server's `ServerHandle::media_read_wait`, over FFI as
/// `media_read_wait`).
///
/// mpv blocked in a read reports neither a stall nor a cache to wait for:
/// its picture stops and it says nothing. The server is the one that knows
/// a read is parked on a piece the swarm has not delivered, and this is
/// what it says about it. A read served off the disk returns in
/// microseconds, so a wait of a second is a read parked on a piece.
final class ReadWait {
  const ReadWait({this.waiting, this.offset});

  /// How long the oldest read still waiting has waited, or null when
  /// nothing waits.
  final Duration? waiting;

  /// Where in the file that read is, or null when nothing waits.
  final int? offset;

  /// Nothing is waiting.
  static const none = ReadWait();

  /// The server's `{waitingMs, offset}`; anything malformed is nothing
  /// waiting, which is what an answer that says nothing means.
  static ReadWait fromJson(Object? value) {
    if (value is! Map) return none;
    final waitingMs = value['waitingMs'];
    final offset = value['offset'];
    return ReadWait(
      waiting: waitingMs is num
          ? Duration(milliseconds: waitingMs.toInt())
          : null,
      offset: offset is num ? offset.toInt() : null,
    );
  }

  /// Whether a read has been waiting at least [threshold].
  bool waitedAtLeast(Duration threshold) {
    final waiting = this.waiting;
    return waiting != null && waiting >= threshold;
  }

  @override
  bool operator ==(Object other) =>
      other is ReadWait && other.waiting == waiting && other.offset == offset;

  @override
  int get hashCode => Object.hash(waiting, offset);

  @override
  String toString() => 'ReadWait(waiting: $waiting, offset: $offset)';
}
