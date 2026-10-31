part of 'player_screen.dart';

/// What the player asks of this device's server while it plays: the
/// torrent's stats, what the server holds of the stream, and the hints it
/// is told.
extension _PlayerServerPolls on _PlayerScreenState {
  /// Puts back the torrent the failure forgot ([_failPlayback] stops the
  /// polling for good), so the stall card and the stats panel have
  /// something to ask about again.
  ///
  /// The start-up cadence [_startTorrentStats] arms belongs to a media
  /// that has not loaded; anything else is whatever wants numbers now.
  void _restoreTorrentStats() {
    final state = _openState;
    if (state == null || _torrentStatsRequest != null) return;
    _startTorrentStats(state);
    if (_mediaLoaded) {
      _torrentPoll.pause();
      _syncStatsPolls();
    }
  }

  /// **Which file of the torrent the player is reading, as its URL spells
  /// it**: the `{fileIdx}` segment the core wrote, `-1` included.
  ///
  /// Not `TorrentStatsRequest.fileIdx`, the addon's, which is often absent. The
  /// core then writes `-1` and the *server* picks the file (the largest video,
  /// narrowed by the URL's `f=` filters, [_openedFilters]). So the segment is
  /// passed through with the filters, and the server resolves them as its
  /// stream route does. Treating `-1` as "no file" would report no length for
  /// most streams.
  int? get _openedFileIdx {
    final segments = _opened?.pathSegments;
    if (segments == null || segments.length < 2) return null;
    return int.tryParse(segments[1]);
  }

  /// The `f=` filters of the URL the player was opened with, which is what
  /// narrows a `-1` to a file; see [_openedFileIdx].
  List<String> get _openedFilters =>
      _opened?.queryParametersAll['f'] ?? const [];

  /// Tells the server how long the film is; see [_onCastStatus].
  ///
  /// By the media id when the torrent is played by one ([_playingMediaId]):
  /// the server knows which file it is, and nothing is taken apart from a
  /// URL. By the URL's own hash, index and filters otherwise.
  Future<void> _reportDuration(Duration duration) async {
    final seconds = duration.inMicroseconds / Duration.microsecondsPerSecond;
    final id = _playingMediaId;
    if (id != null) {
      try {
        await _playbackHints?.noteMediaDuration(
          id: id,
          durationSeconds: seconds,
        );
      } catch (_) {
        // A hint; see below.
      }
      return;
    }
    final request = _torrentStatsRequest;
    final fileIdx = _openedFileIdx;
    if (request == null || fileIdx == null) return;
    try {
      await _playbackHints?.noteDuration(
        infoHash: request.infoHash,
        fileIdx: fileIdx,
        filters: _openedFilters,
        durationSeconds: seconds,
      );
    } catch (_) {
      // A hint, like the playhead: one that does not arrive costs the
      // freshness of a hint.
    }
  }

  /// Tells the server a player opened on the torrent played by media id
  /// [id], once per id; see [_reportPlayerOpened]. Called when the id has
  /// resolved ([_playable]) and the engine's `open` is on its way, which is
  /// the first moment the server knows which torrent it is.
  Future<void> _reportMediaOpened(String id) async {
    if (_mediaOpenedReported == id) return;
    _mediaOpenedReported = id;
    try {
      await _playbackHints?.noteMediaPlayerOpened(id: id);
    } catch (_) {
      // A hint; see [_reportDuration].
    }
  }

  /// Tells the server a player opened on the torrent, so the stalls it goes
  /// on to report are counted for this video; see [_reportStall]. Once per
  /// torrent, and only for one the engine plays by its route; one played by
  /// id reports by id ([_reportMediaOpened]).
  Future<void> _reportPlayerOpened(String infoHash) async {
    if (_mediaOpenedReported == infoHash) return;
    _mediaOpenedReported = infoHash;
    try {
      await _playbackHints?.notePlayerOpened(infoHash: infoHash);
    } catch (_) {
      // A hint; see [_reportDuration].
    }
  }

  /// Tells the server the buffering popup is up while the video was playing
  /// normally, which has it split one more piece ahead of the reader for the
  /// rest of this video. Not the wait after an open or a seek: that is a window
  /// filling, which the server sizes from the film's rate on its own
  /// ([StallAccount.counts]). Only for a torrent this server is streaming, since
  /// the count is that engine's.
  Future<void> _reportStall() async {
    final request = _torrentStatsRequest;
    if (request == null || !_stallAccount.counts) return;
    final id = _playingMediaId;
    try {
      if (id != null) {
        await _playbackHints?.noteMediaPlayerStalled(id: id);
        return;
      }
      await _playbackHints?.notePlayerStalled(infoHash: request.infoHash);
    } catch (_) {
      // A hint; see [_reportDuration].
    }
  }

  /// Tells the server where the viewer is leaving a torrent played by id,
  /// so the next playback resuming near here asks for it first. A hint.
  void _reportLeavingPosition() {
    final id = _playingMediaId;
    final hints = _playbackHints;
    if (id == null || hints == null || _torrentStatsRequest == null) return;
    if (_casting) return;
    final position = _position.value;
    if (position <= Duration.zero) return;
    unawaited(() async {
      try {
        await hints.noteMediaPosition(
          id: id,
          positionSeconds:
              position.inMicroseconds / Duration.microsecondsPerSecond,
        );
      } catch (_) {
        // A hint; see [_reportDuration].
      }
    }());
  }

  // --- Torrent start-up ----------------------------------------------------

  /// Begins polling the server's stats for the torrent [state] plays (see
  /// [TorrentStatsRequest.forStream]). A direct HTTP stream shows no overlay.
  /// The first request goes out on the first tick, never before the engine's
  /// `open` has been issued.
  ///
  /// Every torrent is served by the embedded server, since the core's streaming
  /// server URL is pinned to it (`core::pin_to_embedded`). So the only torrent
  /// not asked about is one in a build that started no embedded server
  /// ([_serverBase] null): there is no engine here to ask. No request means no
  /// swarm rows, no start-up card and no stall card.
  void _startTorrentStats(PlayerState state) {
    _stopTorrentStats();
    final stream = state.selectedStream;
    if (stream?.kind != StreamKind.torrent) return;
    if (_serverBase == null) return;
    final request = TorrentStatsRequest.forStream(stream);
    if (request == null) return;
    _torrentPoll.start(request);
    _refreshDhtStatus();
  }

  /// Reads the DHT's status once, for the start-up card's one explanation (a
  /// trackerless magnet on a network where it never bootstrapped) and the stats
  /// panel's own row. Whether people can connect in through the router is read
  /// at the same moment, for the panel's `router` row. Never on a timer: it is
  /// called only here, when this torrent's polling begins. It never throws: a
  /// provider that fails (the server not up yet) simply shows nothing.
  void _refreshDhtStatus() {
    _dhtStatus = _readOrNull(_dhtStatusProvider);
    _portForwardingStatus = _readOrNull(_portForwardingStatusProvider);
  }

  /// What [provider] answers, or null when there is none or it throws.
  static T? _readOrNull<T>(T Function()? provider) {
    if (provider == null) return null;
    try {
      return provider();
    } on Object {
      return null;
    }
  }

  /// Stops polling for good and forgets the torrent: this player will not
  /// ask about it again. Callers that need a rebuild wrap this in
  /// `setState`.
  void _stopTorrentStats() {
    _torrentPoll.stop();
    _dhtStatus = null;
  }

  /// Both of the player's polls of the server, put back in step with whoever is
  /// reading them. Every path that changes what wants numbers calls this one:
  /// the media loading, a stall starting or ending, the app going behind and
  /// coming back, the stats panel opening and closing. The two polls answer
  /// different questions on the same occasions. The swarm rows want a torrent;
  /// the cache and sharing rows want only a stream and a panel to draw them on.
  void _syncStatsPolls() {
    _syncTorrentStats();
    _syncStreamNumbers();
  }

  /// Keeps the polling in step with whoever wants the numbers, from
  /// [_onMediaLoaded], [_onBuffering], the app going behind and back, and
  /// every change of the stats OSD's visibility. Once the media has loaded,
  /// a torrent's stats are wanted while playback is stalled (the stall card
  /// measures them) and, more slowly, while the OSD shows them. Anything
  /// else (no watcher, a backgrounded app, a direct stream, a failure that
  /// cleared the request) leaves no timer behind.
  void _syncTorrentStats() {
    if (!_mediaLoaded || _torrentStatsRequest == null) return;
    final cadence = _appHidden
        ? null
        : _waiting
        ? PlayerScreen.torrentStallStatsInterval
        : _statsVisible
        ? PlayerScreen.torrentStatsOverlayInterval
        : null;
    if (cadence == null) {
      _torrentPoll.pause();
      // Nobody wants numbers, but the subtitle memory still wants the name of
      // the file the server opened (the release a shift is keyed on). A torrent
      // that loaded before the first poll came back has never been told one, so
      // this is the one ask that would otherwise never happen. Not in the
      // background, which asks the server for nothing; coming back runs this
      // again.
      if (!_appHidden && _serverFilename == null) _torrentPoll.poll();
      return;
    }
    _torrentPoll.run(cadence, keepLast: _statsVisible);
  }

  // --- What the server holds of this stream -------------------------------

  /// The URL the stats panel's rows are asked about, or null where there is
  /// nothing this server could answer for.
  ///
  /// [_engineUrl], not [_opened]: the bytes are cached under the URL the engine
  /// was handed (a `/proxy` URL for anything not a torrent), and the server
  /// finds the store by path, so the bare origin would find nothing. A torrent
  /// played by id is asked about by its id instead ([StreamNumbersPoll]), and
  /// has no URL here. Otherwise only a URL on the embedded server counts: a
  /// loopback one ([isEmbeddedServerHost]). Every stream the engine is handed
  /// is one, unless this build started no embedded server ([_serverBase] null).
  /// `buffer=` stays on: the server ignores every query key but `f=`.
  Uri? get _heldStreamUrl {
    final url = _engineUrl;
    if (url == null || _serverBase == null) return null;
    return isEmbeddedServerHost(url.host) ? url : null;
  }

  /// Drops the last answer and starts again for the stream now open. Called
  /// where [_startTorrentStats] is, and for the same reason: a window and a
  /// ratio belong to one stream, and the previous video's are not a slower
  /// reading of this one.
  void _startStreamNumbers() {
    _stopStreamNumbers();
    _syncStreamNumbers();
  }

  /// Polls for as long as the panel that draws these rows is up and the app is
  /// in front, and not otherwise. Nothing else in the player reads them, and
  /// the ask costs the server a listing of the stream's own directories. Unlike
  /// the swarm, this does not wait for the media to load. What it reports is
  /// what is on the disk, which is exactly what somebody watching a stream that
  /// has not started yet is looking for.
  void _syncStreamNumbers() {
    if (_appHidden || !_statsVisible || _opened == null) {
      _stopStreamNumbers();
      return;
    }
    _numbersPoll.run();
  }

  /// Stops the panel's poll, and drops its last reading ([StreamNumbersPoll.stop]).
  void _stopStreamNumbers() => _numbersPoll.stop();
}
