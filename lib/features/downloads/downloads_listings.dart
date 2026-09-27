import '../../core/core.dart';

/// Takes listings of the registry while the progress feed keeps arriving,
/// and answers each with what the feed said while it was being taken.
///
/// A listing is a round trip over FFI, so a progress row can land and
/// describe the registry as it now is while a listing already in flight
/// still describes how it was before that row; overwriting the registry
/// with such a listing would throw the row away. Nothing resends it: the
/// Rust side sends a row only when it differs from the last one sent, and
/// its ticker stops once nothing is unfinished -- so the row lost is
/// usually the last one, a download completing, leaving the registry (and
/// the foreground service waiting on it) believing it is still short of
/// done.
///
/// Laying the rows heard during a listing over its answer is safe whichever
/// side of the listing they were sent on: a row carries the entry's numbers
/// whole, the rows arrive in the order they were sent, and so the last one
/// laid is the newest thing known about that entry.
class DownloadsListings {
  final List<List<DownloadsUpdate>> _inFlight = [];
  int _asked = 0;
  int _landed = 0;

  /// Every update the feed delivers goes through here, so a listing in
  /// flight can lay it over its answer.
  void heard(DownloadsUpdate update) {
    for (final missed in _inFlight) {
      missed.add(update);
    }
  }

  /// [list]'s answer with the updates heard while it was taken laid over
  /// it, or null when a listing asked for after this one has landed first:
  /// that one is newer, and this one would put back what it had replaced.
  /// A [list] that throws throws here.
  Future<DownloadsRegistry?> take(
    Future<DownloadsRegistry> Function() list,
  ) async {
    final asked = ++_asked;
    final missed = <DownloadsUpdate>[];
    _inFlight.add(missed);
    DownloadsRegistry listing;
    try {
      listing = await list();
    } finally {
      _inFlight.remove(missed);
    }
    if (asked < _landed) return null;
    _landed = asked;
    for (final update in missed) {
      listing = update.applyTo(listing);
    }
    return listing;
  }
}
