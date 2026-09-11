import '../../core/core.dart';

/// Takes listings of the registry while the progress feed keeps arriving,
/// and answers each with what the feed said while it was being taken.
///
/// A listing is a round trip over FFI, and a progress row can land inside
/// it. The row describes the registry as it is; the listing that comes
/// back after it can describe the registry as it was before. Put in the
/// registry's place, that listing threw the row away. Nothing sends it
/// again: the Rust side sends a row only when it differs from the one it
/// sent last, and its ticker stops once nothing is unfinished. So the row
/// lost was usually the last one, a download completing, and whoever held
/// the registry went on believing it was at 99 % -- the foreground service
/// held the process up for it until the process died.
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
