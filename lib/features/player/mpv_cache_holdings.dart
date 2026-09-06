/// What this app's live players are holding on the volume, all of them at
/// once.
///
/// `MpvDiskCacheLimit` bounds one media, and every limiter believes it is
/// alone. That was true while a player was the only thing on screen and
/// stopped being true the moment two of them overlapped: on the owner's
/// Chromecast a 512 MiB cap let 928 MB go, because a hand-over ran two
/// demuxers at once and each was under its own limit throughout. A cap
/// that cannot be added up is not a cap on the device.
///
/// So the number is kept in one place a player registers with rather than
/// derived from the players, and it answers two questions that a
/// per-media limiter cannot:
///
/// - **May this file still grow?** [heldBytes] is what the app's cap is
///   held against, so two players share one 512 MiB allowance rather than
///   taking one each.
/// - **May a new media have a cache file at all?** [heldByOthers] is what
///   `MediaKitEngine.open` asks before it writes `cache-on-disk`, so a
///   player starting while the allowance is already spent plays out of
///   memory instead of opening a second writer on a full device.
///
/// **It is what the players hold, not what is on the volume.** mpv unlinks
/// its cache file the moment it creates it, so no directory walk can find
/// those blocks and the free-space reading is the only other place they
/// appear -- as space that is simply gone, with nothing to say who has it.
/// This is the app saying so, and the only number in the process that
/// knows.
///
/// A player is one entry from the `loadfile` that gives it a cache file
/// until the teardown that closes the fd, because that is exactly how long
/// the blocks are allocated for -- a player told to stop writing keeps its
/// entry, since what it has already written is still held. The later
/// shared budget between this and the server's own cache divides the same
/// volume, and this is the half of it the player can answer for.
class MpvCacheHoldings {
  /// The one the app's players report to. A process has one set of live
  /// players and one volume under them, so there is one of these.
  static final MpvCacheHoldings shared = MpvCacheHoldings();

  /// What each live player last measured in its own cache file. Keyed by
  /// the player itself, so a player that is replaced mid-session takes its
  /// entry with it rather than leaving a number nobody owns.
  final Map<Object, int> _held = {};

  /// What every live player holds together.
  int get heldBytes => _held.values.fold(0, (total, bytes) => total + bytes);

  /// How many players have a cache file open.
  int get openFiles => _held.length;

  /// What everything except [player] holds -- the question a player asks
  /// about the room it is moving into, where its own file is either about
  /// to be freed by the `loadfile` or not there yet.
  int heldByOthers(Object player) => heldBytes - (_held[player] ?? 0);

  /// Records that [player] is holding [bytes], and answers the new total.
  int hold(Object player, int bytes) {
    _held[player] = bytes;
    return heldBytes;
  }

  /// Forgets [player]: its fd is closed, or it never had a file.
  void release(Object player) => _held.remove(player);
}
