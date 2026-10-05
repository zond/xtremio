part of 'player_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

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
      _pauseTorrentStats();
      _syncStatsPolls();
    }
  }

  /// **Which file of the torrent the player is reading, as its URL spells
  /// it**: the `{fileIdx}` segment the core wrote, `-1` included.
  ///
  /// Not `TorrentStatsRequest.fileIdx`, the addon's, which is often absent:
  /// the core then writes `-1` and the *server* picks the file (the largest
  /// video, narrowed by the URL's `f=` filters, [_openedFilters]). So the
  /// segment is passed through with the filters and the server resolves them
  /// as its stream route does; treating `-1` as "no file" would report no
  /// length for most streams.
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
  /// resolved ([_resolveMedia]), which is the first moment the server
  /// knows which torrent it is.
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
  /// on to report are counted for this video; see [_reportStall]. Only for
  /// a torrent not played by id; one that is reports by id
  /// ([_reportMediaOpened]).
  Future<void> _reportPlayerOpened(String infoHash) async {
    try {
      await _playbackHints?.notePlayerOpened(infoHash: infoHash);
    } catch (_) {
      // A hint; see [_reportDuration].
    }
  }

  /// Tells the server the buffering popup is up while the video was playing
  /// normally -- what has it split one more piece ahead of the reader for
  /// the rest of this video. Not the wait after an open or a seek, which is
  /// a window filling and which the server sizes from the film's rate on
  /// its own ([_playingNormally]); and only a torrent this server is
  /// streaming, since the count is that engine's.
  Future<void> _reportStall() async {
    final request = _torrentStatsRequest;
    if (request == null || !_playingNormally) return;
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

  /// One ask of the read-wait readout ([_readStalled]), for the torrent
  /// the engine reads by media id.
  ///
  /// The card goes up when a read has waited [PlayerScreen.readWaitShown]
  /// while the picture stood still since the last ask, and comes down at
  /// the first ask that finds reads flowing -- whatever the read is: the
  /// file's head, its index, the resume point. No give-up: a read that
  /// waits for ever keeps the card up for ever, and the viewer decides.
  Future<void> _pollReadWait() async {
    final id = _playingMediaId;
    final reader = _streamNumbersReader;
    if (!mounted ||
        id == null ||
        reader == null ||
        _torrentStatsRequest == null ||
        _casting ||
        _handedOver ||
        _appHidden ||
        _readWaitFetching) {
      return;
    }
    final position = _position.value;
    _readWaitFetching = true;
    ReadWait wait;
    try {
      wait = await reader.mediaReadWait(id);
    } on Object {
      wait = ReadWait.none;
    } finally {
      _readWaitFetching = false;
    }
    if (!mounted || _playingMediaId != id) return;
    final from = _readWaitFrom;
    _readWaitFrom = position;
    final still =
        from != null && (position - from).abs() < PlayerScreen.stuckTwitch;
    final stalled =
        _mediaLoaded &&
        _playing &&
        still &&
        wait.waitedAtLeast(PlayerScreen.readWaitShown);
    if (stalled == _readStalled) return;
    if (stalled) {
      DiagnosticsLog.warn(
        'player',
        'a read has waited ${wait.waiting?.inMilliseconds}ms at byte '
            '${wait.offset} with the picture still at '
            '${position.inSeconds}s; buffering from the torrent',
      );
    } else {
      DiagnosticsLog.info(
        'player',
        'reads are flowing again at ${position.inSeconds}s',
      );
    }
    setState(() => _readStalled = stalled);
    _syncStatsPolls();
  }

  // --- Torrent start-up ----------------------------------------------------

  /// Begins polling the server's stats for the torrent [state] plays (see
  /// [TorrentStatsRequest.forStream]); a direct HTTP stream shows no
  /// overlay. The first request goes out on the first tick, never before the
  /// engine's `open` has been issued.
  ///
  /// Every torrent is served by the embedded server -- the core's streaming
  /// server URL is pinned to it (`core::pin_to_embedded`) -- so the only
  /// torrent not asked about is one in a build that started no embedded
  /// server ([_serverBase] null): there is no engine here to ask. No
  /// request means no swarm rows, no start-up card and no stall card.
  void _startTorrentStats(PlayerState state) {
    _stopTorrentStats();
    final stream = state.selectedStream;
    if (stream?.kind != StreamKind.torrent) return;
    if (_serverBase == null) return;
    final request = TorrentStatsRequest.forStream(stream);
    if (request == null) return;
    _torrentStatsRequest = request;
    // A torrent registered as a media id ([_register], which ran first)
    // is reported opened by id once the engine has it; only one played by
    // its URL is reported by its hash.
    if (_mediaIdSource != _opened) _reportPlayerOpened(request.infoHash);
    final fallback = request.torrentLevel;
    _torrentStatsFallback = fallback == request ? null : fallback;
    _startStartupPolling();
    _refreshDhtStatus();
  }

  /// Arms the start-up cadence ([PlayerScreen.torrentStatsInterval]) for
  /// the torrent [_startTorrentStats] set up, or leaves it running if it
  /// already is. The first request goes out on the first tick, never at
  /// once (see [_startTorrentStats]); the app coming back to the front
  /// during start-up re-arms it here ([_onAppShown]).
  void _startStartupPolling() {
    if (_torrentStatsTimer != null &&
        _torrentStatsCadence == PlayerScreen.torrentStatsInterval) {
      return;
    }
    _torrentStatsTimer?.cancel();
    _torrentStatsCadence = PlayerScreen.torrentStatsInterval;
    _torrentStatsTimer = Timer.periodic(
      PlayerScreen.torrentStatsInterval,
      (_) => _pollTorrentStats(),
    );
  }

  /// Reads the DHT's status once: for the start-up card's one explanation
  /// (a trackerless magnet on a network where it never bootstrapped) and
  /// the stats panel's own row. Never on a timer -- called only here, when
  /// this torrent's polling begins -- and never throws: a provider that
  /// fails (the server not up yet) simply shows nothing.
  void _refreshDhtStatus() {
    final provider = _dhtStatusProvider;
    if (provider == null) {
      _dhtStatus = null;
      return;
    }
    try {
      _dhtStatus = provider();
    } on Object {
      _dhtStatus = null;
    }
  }

  /// Stops polling for good and forgets the torrent: this player will not
  /// ask about it again. Callers that need a rebuild wrap this in
  /// `setState`.
  void _stopTorrentStats() {
    _pauseTorrentStats();
    _torrentStats = null;
    _torrentStatsRequest = null;
    _torrentStatsFallback = null;
    _serverFilename = null;
    _dhtStatus = null;
  }

  /// Stops polling but keeps the torrent, so a stall or the stats OSD can
  /// pick it up again. The last answer outlives the timer, because a pause
  /// is often only the panel going away for a moment (hovering off, on a
  /// desktop) and the numbers it showed are still the numbers to show when
  /// it comes back; [_syncTorrentStats] is where they are dropped as too
  /// old to show.
  void _pauseTorrentStats() {
    _torrentStatsTimer?.cancel();
    _torrentStatsTimer = null;
    _torrentStatsCadence = null;
  }

  /// Both of the player's polls of the server, put back in step with
  /// whoever is reading them. Every path that changes what wants numbers
  /// calls this one -- the media loading, a stall starting or ending, the
  /// app going behind and coming back, the stats panel opening and
  /// closing -- because the two answer different questions on the same
  /// occasions: the swarm rows want a torrent, the cache and sharing rows
  /// want only a stream and a panel to draw them on.
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
      _pauseTorrentStats();
      // Nobody wants numbers, but the subtitle memory still wants the name
      // of the file the server opened (the release a shift is keyed on),
      // and a torrent that loaded before the first poll came back has never
      // been told one: this is the one ask that would otherwise never
      // happen. Not in the background, which asks the server for nothing;
      // coming back runs this again.
      if (!_appHidden && _serverFilename == null) _pollTorrentStats();
      return;
    }
    if (_torrentStatsTimer != null && _torrentStatsCadence == cadence) return;
    // A stall that starts under an open OSD (or ends under one) changes
    // only the pace: the last answer stands until the next one lands. The
    // same goes for a panel that comes back before the answer does. Wanting
    // the numbers again after nothing was showing them is another matter:
    // those describe a start-up, or a stall, however long ago, and the
    // stall card showing them would be stating the past as the present.
    if (_torrentStatsTimer == null && !_statsVisible) _torrentStats = null;
    _torrentStatsTimer?.cancel();
    _torrentStatsCadence = cadence;
    _torrentStatsTimer = Timer.periodic(cadence, (_) => _pollTorrentStats());
    // Unlike the start-up poll this one goes out at once: the stream
    // request created the torrent's engine long ago, so there is no
    // ordering to respect, and whoever just started watching wants numbers
    // now, not in two seconds.
    _pollTorrentStats();
  }

  /// One poll: the per-file stats, or the torrent-level ones when the
  /// server has no answer for the file (an index the torrent does not
  /// have; a stopped server fails the second ask as fast as the first).
  Future<void> _pollTorrentStats() async {
    final request = _torrentStatsRequest;
    final fallback = _torrentStatsFallback;
    final client = _torrentStatsClient;
    if (request == null || client == null || _torrentStatsFetching) return;
    _torrentStatsFetching = true;
    TorrentStats? stats;
    // Whether the answer is about the file being streamed rather than the
    // torrent as a whole. It matters for the name below: the torrent-level
    // `streamName` is the file the server *guessed*, which is the streamed
    // one only when the stream carried no `fileIdx` -- and then the primary
    // request is the torrent-level one anyway.
    var aboutTheFile = false;
    try {
      stats = await client.fetch(request);
      aboutTheFile = stats != null;
      if (stats == null &&
          fallback != null &&
          _torrentStatsRequest == request) {
        stats = await client.fetch(fallback);
      }
    } on Object {
      stats = null;
      aboutTheFile = false;
    } finally {
      _torrentStatsFetching = false;
    }
    final opened = aboutTheFile ? stats?.streamName : null;
    if (!mounted || _torrentStatsRequest != request) return;
    // The numbers describe a moment, so an answer that came back after the
    // polling stopped -- a stall that ended while the fetch was out -- is
    // not one to show. The name is not a moment: which file this is does
    // not go stale, and the poll that carries it is very often the last
    // one there will be, since the polling stops for good once playback is
    // under way. A poll that came back empty says nothing about the file
    // the server opened; only an answer that names one replaces the name.
    final names = opened != null && opened != _serverFilename;
    final counts = _torrentStatsTimer != null && stats != _torrentStats;
    if (!names && !counts) return;
    setState(() {
      if (counts) _torrentStats = stats;
      if (names) _serverFilename = opened;
    });
  }

  // --- What the server holds of this stream -------------------------------

  /// The URL the stats panel's rows are asked about, or null where there is
  /// nothing this server could answer for.
  ///
  /// [_engineUrl], not [_opened]: the bytes are cached under the URL the
  /// engine was handed (a `/proxy` URL for anything not a torrent), and the
  /// server finds the store by path, so the bare origin would find nothing.
  /// A torrent played by id is asked about by its id instead
  /// ([_pollStreamNumbers]), and has no URL here. Otherwise only a URL on
  /// the embedded server: a loopback one ([isEmbeddedServerHost]), which
  /// every stream the engine is handed is unless this build started no
  /// embedded server ([_serverBase] null). `buffer=` stays on: the server
  /// ignores every query key but `f=`.
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

  /// Polls for as long as the panel that draws these rows is up and the app
  /// is in front, and not otherwise: nothing else in the player reads them,
  /// and the ask costs the server a listing of the stream's own
  /// directories. Unlike the swarm this does not wait for the media to
  /// load -- what it reports is what is on the disk, which is exactly what
  /// somebody watching a stream that has not started yet is looking for.
  void _syncStreamNumbers() {
    if (_appHidden || !_statsVisible || _opened == null) {
      _stopStreamNumbers();
      return;
    }
    if (_streamNumbersTimer != null) return;
    _streamNumbersTimer = Timer.periodic(
      PlayerScreen.streamNumbersInterval,
      (_) => _pollStreamNumbers(),
    );
    // At once rather than in five seconds: whoever just opened the panel
    // wants the numbers now.
    _pollStreamNumbers();
  }

  /// Stops polling and drops the last answer, which are one act. What was
  /// on the panel described the moment it was measured in; kept past its
  /// poll it would come back on screen -- the panel reopened, the app
  /// brought forward, the next video started -- as a reading of something
  /// it was never taken from.
  void _stopStreamNumbers() {
    _streamNumbersTimer?.cancel();
    _streamNumbersTimer = null;
    _streamNumbers = null;
  }

  /// One ask, for the media id the engine reads or else [_heldStreamUrl],
  /// and nothing when there is neither.
  /// Decided per ask because what the engine was handed can change under an
  /// open panel (a re-open for a new buffer window).
  ///
  /// An answer that comes back after the stream changed ([_opened], not the
  /// URL, says which video), or after the polling stopped, is not shown.
  /// Every failure is no rows: the server not running and a stream it does
  /// not hold both mean there is nothing to draw.
  Future<void> _pollStreamNumbers() async {
    final id = _serverBase == null
        ? null
        : (_registeredMediaId ?? _playingMediaId);
    final url = _heldStreamUrl;
    final playing = _opened;
    final reader = _streamNumbersReader;
    if ((id == null && url == null) ||
        reader == null ||
        _streamNumbersFetching) {
      return;
    }
    _streamNumbersFetching = true;
    StreamNumbers? numbers;
    try {
      numbers = id != null
          ? await reader.mediaStreamNumbers(id)
          : await reader.streamNumbers(url!);
    } on Object {
      numbers = null;
    } finally {
      _streamNumbersFetching = false;
    }
    if (!mounted || _opened != playing || _streamNumbersTimer == null) return;
    if (numbers?.isEmpty ?? false) numbers = null;
    if (numbers == _streamNumbers) return;
    setState(() => _streamNumbers = numbers);
  }
}
