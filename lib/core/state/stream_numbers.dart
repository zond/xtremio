/// What the embedded server holds of the stream a player is inside, right
/// now (`ServerHandle::stream_numbers`, read over FFI as
/// `server_stream_numbers`).
///
/// One question, asked with the one thing a client already holds that names
/// the stream: the URL it handed its player. The URL's shape is what
/// decides which of the server's two stores answers -- the piece store for
/// a torrent, the proxy cache for a proxied response -- and a URL neither
/// holds is no [StreamNumbers] at all rather than an error. That is the
/// ordinary case for a stream this server never touched: an addon's direct
/// link, a debrid URL, a file on the device.
///
/// **Every absence here is "there is no such number", never zero**, and
/// every one of them is a row a panel must leave out rather than draw with
/// a dash: a dash reads as a measured nothing, which is the opposite of
/// what an absence means. See each field.
///
/// **Nothing here is stored, on either side.** The server measures each
/// number when it is asked for -- a listing of the stream's own
/// directories, a counter read off the torrent's live state -- and keeps
/// nothing between calls, so nothing in a reading is a claim about a past
/// the process never saw. At process start there is no playhead in either
/// store, so there is no window to read: the honest answer for a process
/// that has watched nothing yet is the absence, and it is the answer this
/// gives.
final class StreamNumbers {
  const StreamNumbers({this.window, this.sharing});

  /// What is on the disk for this stream, split at the playhead, or null
  /// where nothing is bounding the stream: no retention policy (the
  /// budget covers the whole file, or none has been published yet) and no
  /// reader that has been anywhere inside it in this process. What is on
  /// the disk without a policy is not a window -- it is whatever of the
  /// file has been fetched, with nothing holding it to the play head, a
  /// different quantity -- so the row is absent rather than carrying both
  /// meanings.
  final CacheWindow? window;

  /// The sharing numbers: torrents only. Null for a proxied response,
  /// which is not seeded -- there is no swarm, so there is no committed
  /// set and no ratio, and the row is absent rather than a line of zeroes.
  final SharingNumbers? sharing;

  /// The numbers in a `stream-numbers.json` body, or null for the `null`
  /// the server answers for a stream it is not holding -- and for anything
  /// malformed, which says the same thing: no rows.
  static StreamNumbers? fromJson(Object? value) {
    if (value is! Map) return null;
    return StreamNumbers(
      window: CacheWindow.fromJson(value['window']),
      sharing: SharingNumbers.fromJson(value['sharing']),
    );
  }

  /// Whether there is anything at all to draw. A [StreamNumbers] with
  /// neither half is what a server that holds the stream but can say
  /// nothing measurable about it answers, and it draws exactly like no
  /// answer.
  bool get isEmpty => window == null && sharing == null;

  @override
  bool operator ==(Object other) =>
      other is StreamNumbers &&
      other.window == window &&
      other.sharing == sharing;

  @override
  int get hashCode => Object.hash(window, sharing);

  @override
  String toString() => 'StreamNumbers(window: $window, sharing: $sharing)';
}

/// What one stream's cache holds around the playhead, in bytes: the
/// retention window's two halves.
///
/// A live reading of a store and nothing else -- the piece store counting
/// pieces of the file, the proxy cache counting chunks of the entity. It is
/// **not the extent the policy intends to fill**: [aheadBytes] is
/// read-ahead that has arrived, and a stream that has fetched nothing yet
/// reads zero rather than the size of the window it is going to have.
final class CacheWindow {
  const CacheWindow({required this.behindBytes, required this.aheadBytes});

  /// Bytes held behind the playhead: what a scan back is served from.
  final int behindBytes;

  /// Bytes held from the playhead on: what playback has in hand. The piece
  /// under the playhead counts here -- it is the one a player is about to
  /// read, not one it has passed.
  final int aheadBytes;

  /// The window in a `window` value, or null for the null the server sends
  /// where nothing is bounding the stream. A half the server did not send
  /// is not half a window: the whole reading is dropped, because a zero
  /// there would say the cache holds nothing on that side.
  static CacheWindow? fromJson(Object? value) {
    if (value is! Map) return null;
    final behind = (value['behindBytes'] as num?)?.toInt();
    final ahead = (value['aheadBytes'] as num?)?.toInt();
    if (behind == null || ahead == null) return null;
    return CacheWindow(behindBytes: behind, aheadBytes: ahead);
  }

  @override
  bool operator ==(Object other) =>
      other is CacheWindow &&
      other.behindBytes == behindBytes &&
      other.aheadBytes == aheadBytes;

  @override
  int get hashCode => Object.hash(behindBytes, aheadBytes);

  @override
  String toString() =>
      'CacheWindow(behind: $behindBytes B, ahead: $aheadBytes B)';
}

/// What a torrent stream has committed to the swarm and moved over it.
final class SharingNumbers {
  const SharingNumbers({
    this.committedBytes,
    this.transfer,
    this.refusedReclaims,
  });

  /// Bytes advertised and promised never to be reclaimed -- the retention
  /// policy's committed set. Null for a torrent with no policy, which has
  /// promised nothing whatever it announces.
  final int? committedBytes;

  /// What the torrent has moved since it last went live, or null where the
  /// backend has no counters to read. See [LiveTransfer].
  final LiveTransfer? transfer;

  /// How many pieces the server's retention passes asked the torrent
  /// backend to forget and were refused, over the life of the engine.
  ///
  /// **Zero is the only healthy value.** A refusal is the backend keeping a
  /// piece an open stream is still reading ahead over while the retention
  /// window has moved off it: the cache cannot come back under its budget
  /// while that stream lives. Null for a proxied stream, which has no
  /// engine and no passes.
  final int? refusedReclaims;

  /// The sharing numbers in a `sharing` value, or null for the null a
  /// proxied stream answers with. A `sharing` with neither half in it is
  /// no sharing row either.
  static SharingNumbers? fromJson(Object? value) {
    if (value is! Map) return null;
    final numbers = SharingNumbers(
      committedBytes: (value['committedBytes'] as num?)?.toInt(),
      transfer: LiveTransfer.fromJson(value['transfer']),
      refusedReclaims: (value['refusedReclaims'] as num?)?.toInt(),
    );
    return numbers.committedBytes == null &&
            numbers.transfer == null &&
            numbers.refusedReclaims == null
        ? null
        : numbers;
  }

  @override
  bool operator ==(Object other) =>
      other is SharingNumbers &&
      other.committedBytes == committedBytes &&
      other.transfer == transfer &&
      other.refusedReclaims == refusedReclaims;

  @override
  int get hashCode => Object.hash(committedBytes, transfer, refusedReclaims);

  @override
  String toString() =>
      'SharingNumbers(committed: $committedBytes B, transfer: $transfer, '
      'refused: $refusedReclaims)';
}

/// What a torrent has fetched and sent **since it last went live**, and
/// the ratio of the two.
///
/// **One live period's, and deliberately not the torrent's.** These are
/// librqbit's own per-torrent counters, which the backend reads out of the
/// live state and out of nowhere else
/// (`enginefs::backend::TransferTotals`: "they start at zero when a torrent
/// goes live and are gone when it leaves that state"). So a pause and
/// resume starts them over, and so does the idle sweep dropping the engine
/// before a later stream re-adds it -- whatever the same torrent moved
/// before that is not in them and is not pretended to be. It is not the
/// process's lifetime either, which is why nothing here says "session".
/// Whoever draws them says which period they cover.
///
/// Not stored, and that is the other half of it. Conventional BitTorrent
/// clients keep a ratio per torrent across restarts; that would mean
/// counters on disk which something then has to keep true, and a stored
/// counter read back as an observation is exactly the claim about an
/// unseen past this codebase keeps having to unship.
///
/// The three stand or fall together, which is why they are one value rather
/// than three fields on [SharingNumbers]: the counters live in a torrent's
/// live state, so one that is paused, checking, stopped for space or in
/// error has none to read -- and a torrent that moved gigabytes and then
/// paused has not moved nothing.
final class LiveTransfer {
  const LiveTransfer({
    required this.downloadedBytes,
    required this.wastedBytes,
    required this.uploadedBytes,
    this.ratio,
  });

  /// Bytes fetched from peers since the torrent last went live.
  final int downloadedBytes;

  /// Of those, the bytes that never became a piece the server kept.
  ///
  /// A few per cent is the end of a download duplicating its last pieces
  /// and is normal. A multiple of what has been watched is the cache
  /// fetching what it is about to delete, which is what this figure exists
  /// to show.
  final int wastedBytes;

  /// Bytes sent to peers since the torrent last went live.
  final int uploadedBytes;

  /// Uploaded over downloaded, the form every BitTorrent client shows.
  ///
  /// Null when nothing has been downloaded: a ratio against zero is not
  /// `0.00`, it is undefined, and a torrent that has uploaded something
  /// must never be drawn as one that has shared nothing.
  final double? ratio;

  /// The transfer in a `transfer` value, or null for the null the server
  /// sends where the counters cannot be read. Either byte count missing
  /// drops the whole group, for the same reason the server sends it as a
  /// group.
  static LiveTransfer? fromJson(Object? value) {
    if (value is! Map) return null;
    final downloaded = (value['downloadedBytes'] as num?)?.toInt();
    final uploaded = (value['uploadedBytes'] as num?)?.toInt();
    if (downloaded == null || uploaded == null) return null;
    return LiveTransfer(
      downloadedBytes: downloaded,
      wastedBytes: (value['wastedBytes'] as num?)?.toInt() ?? 0,
      uploadedBytes: uploaded,
      ratio: (value['ratio'] as num?)?.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LiveTransfer &&
      other.downloadedBytes == downloadedBytes &&
      other.wastedBytes == wastedBytes &&
      other.uploadedBytes == uploadedBytes &&
      other.ratio == ratio;

  @override
  int get hashCode =>
      Object.hash(downloadedBytes, wastedBytes, uploadedBytes, ratio);

  @override
  String toString() =>
      'LiveTransfer(down: $downloadedBytes B, wasted: $wastedBytes B, '
      'up: $uploadedBytes B, ratio: $ratio)';
}
