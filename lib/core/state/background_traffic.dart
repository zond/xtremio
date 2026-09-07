/// Whether the embedded server is using this device's connection while
/// nothing is playing, in each direction
/// (`ServerHandle::background_traffic`, read over FFI as
/// `server_background_traffic`).
///
/// This is the reading the activity light wants: "Xtremio is moving bytes
/// over your connection and you are not watching", judged by the server
/// over a window of [windowSecs] seconds from librqbit's own per-torrent
/// peer counters, summed over the torrents that exist. Serving a peer
/// counts, and so does an offline download filling in; what a viewer is
/// told about is the connection, not who is at the other end.
///
/// **Both halves are already conjoined with "nothing playing", on the Rust
/// side.** A client reading traffic and playback as two calls would sample
/// them a moment apart and get a light that flickers whenever they
/// disagree, so [downloading] and [uploading] are each "that direction's
/// counter grew over the last window and no player was seen reading over
/// it or since", and [active] is either. [playing] is the moment's own
/// answer, kept so a caller can tell "dark because idle" from "dark because
/// a film is on" without a second call.
///
/// It is a reading, never a claim: nothing here derives from the sharing
/// setting, so a viewer who has turned sharing on but is uploading nothing
/// reads exactly as one who turned it off. And it is cheap to poll -- the
/// server peeks at counters it already keeps, creates no engine and
/// touches no idle clock, so asking every few seconds is what it is for.
class BackgroundTraffic {
  const BackgroundTraffic({
    required this.active,
    required this.downloading,
    required this.uploading,
    required this.playing,
    required this.bytesDownloaded,
    required this.bytesUploaded,
    required this.windowSecs,
  });

  /// A missing key reads as its dark value: the light must never come on
  /// for a field the server did not answer.
  factory BackgroundTraffic.fromJson(Map<String, dynamic> json) =>
      BackgroundTraffic(
        active: json['active'] as bool? ?? false,
        downloading: json['downloading'] as bool? ?? false,
        uploading: json['uploading'] as bool? ?? false,
        playing: json['playing'] as bool? ?? false,
        bytesDownloaded: (json['bytesDownloaded'] as num?)?.toInt() ?? 0,
        bytesUploaded: (json['bytesUploaded'] as num?)?.toInt() ?? 0,
        windowSecs: (json['windowSecs'] as num?)?.toInt() ?? 0,
      );

  /// Nothing moving, nothing playing, nothing known: every field at its
  /// dark value. What a caller holds before its first reading and after a
  /// failed one, since not knowing is drawn exactly like nothing moving --
  /// a light that cannot tell the two apart stays off for both, and off is
  /// the answer that claims nothing.
  static const BackgroundTraffic none = BackgroundTraffic(
    active: false,
    downloading: false,
    uploading: false,
    playing: false,
    bytesDownloaded: 0,
    bytesUploaded: 0,
    windowSecs: 0,
  );

  /// `downloading || uploading`: the connection is in use while nobody is
  /// watching, whichever way the bytes went. The one-glyph answer; the two
  /// halves are the three-glyph one.
  final bool active;

  /// Bytes came in from peers over the last closed window, and nothing
  /// was playing over it or since.
  final bool downloading;

  /// Bytes went out to peers over the last closed window, and nothing was
  /// playing over it or since.
  final bool uploading;

  /// Whether a player is reading from the server as this was answered.
  final bool playing;

  /// The sums the verdict was judged from: bytes received from and sent to
  /// peers, over the torrents that exist right now -- not since the
  /// process started, since a torrent that pauses or leaves takes its bytes
  /// with it. Two readings apart in time say whether anything moved, as
  /// long as the set of torrents held still in between.
  final int bytesDownloaded;
  final int bytesUploaded;

  /// The window the halves were judged over, in seconds.
  final int windowSecs;

  @override
  bool operator ==(Object other) =>
      other is BackgroundTraffic &&
      other.active == active &&
      other.downloading == downloading &&
      other.uploading == uploading &&
      other.playing == playing &&
      other.bytesDownloaded == bytesDownloaded &&
      other.bytesUploaded == bytesUploaded &&
      other.windowSecs == windowSecs;

  @override
  int get hashCode => Object.hash(
    active,
    downloading,
    uploading,
    playing,
    bytesDownloaded,
    bytesUploaded,
    windowSecs,
  );

  @override
  String toString() =>
      'BackgroundTraffic(active: $active, downloading: $downloading, '
      'uploading: $uploading, playing: $playing, '
      '$bytesDownloaded B down, $bytesUploaded B up, over ${windowSecs}s)';
}
