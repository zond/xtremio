part of 'player_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// What the player asks of this device's server while it plays: the
/// torrent's stats, what the server holds of the stream, and the hints it
/// is told.
extension _PlayerServerPolls on _PlayerScreenState {
  /// Whether [url] is a stream this device's embedded server is the one
  /// serving -- the single rule behind both of the questions this screen
  /// asks that server about a stream ([_heldStreamUrl] and
  /// [_startTorrentStats]).
  ///
  /// The server answers on the path and the `f=` query alone and says so
  /// deliberately (`stream_numbers::parse`: the host a caller would have
  /// to invent to be allowed to ask decides nothing), and the stats route
  /// takes an info hash with no host in it at all. Neither can tell whose
  /// stream it is being asked about, so it is whoever asks that has to
  /// only ask about streams this server serves -- and with a streaming
  /// server configured on another machine a torrent is not one of them:
  /// it has an info hash, so [_mediaUrl] sends it straight to that machine
  /// with `buffer=` and no proxy, while the embedded server here keeps
  /// running and would answer for the same hash out of *its* own engine.
  ///
  /// Which is the milder half of it for the stats route, because asking
  /// creates that engine (`ServerClient.torrentStats`): a film playing off
  /// somebody else's box would start an add on this device, and the
  /// panel's speed, seeds and peers rows -- and the start-up and stall
  /// cards behind them -- would then be measuring that local add rather
  /// than the playback they are drawn over.
  ///
  /// False with no embedded server at all ([_serverBase] null): there is
  /// no server here to have served anything.
  bool _servedHere(Uri? url) =>
      url != null && isEmbeddedServer(url, _serverBase);

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
  /// it** -- the `{fileIdx}` segment the core wrote, `-1` included.
  ///
  /// Not from `TorrentStatsRequest.fileIdx`, which is the *addon's* -- and
  /// an addon frequently does not say. The core then writes `-1` and the
  /// *server* picks the file (the largest video, narrowed by the URL's
  /// `f=` filters, [_openedFilters]); nothing on this side knows which.
  /// So the segment is passed through as it is, filters beside it, and the
  /// server resolves the two by the rule its stream route uses. Treating
  /// `-1` as "no file" here meant a length was never reported for exactly
  /// the streams whose addon named no file, which is most of them.
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
  Future<void> _reportDuration(Duration duration) async {
    final request = _torrentStatsRequest;
    final fileIdx = _openedFileIdx;
    if (request == null || fileIdx == null) return;
    try {
      await _playbackHints?.noteDuration(
        infoHash: request.infoHash,
        fileIdx: fileIdx,
        filters: _openedFilters,
        durationSeconds:
            duration.inMicroseconds / Duration.microsecondsPerSecond,
      );
    } catch (_) {
      // A hint, like the playhead: one that does not arrive costs the
      // freshness of a hint.
    }
  }

  /// Tells the server a player opened on the torrent, so the stalls it goes
  /// on to report are counted for this video; see [_reportStall].
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
    try {
      await _playbackHints?.notePlayerStalled(infoHash: request.infoHash);
    } catch (_) {
      // A hint; see [_reportDuration].
    }
  }

  // --- Torrent start-up ----------------------------------------------------

  /// Begins polling the server's stats for the torrent [state] plays (see
  /// [TorrentStatsRequest.forStream]); anything else (a direct HTTP stream)
  /// shows no overlay. The first request goes out on the first tick, never
  /// before the engine's `open` has been issued.
  ///
  /// A torrent, and one this device's server is the one serving
  /// ([_servedHere], read off the URL [_open] has just handed the engine).
  /// A torrent playing off a streaming server on another machine is not
  /// ours to ask about: this server would answer out of an engine of its
  /// own for that hash -- and, asked, would start one. No request means no
  /// polling, and so no swarm rows, no start-up card and no stall card,
  /// which is right, because every one of them would be describing that
  /// local engine and not the playback on screen.
  void _startTorrentStats(PlayerState state) {
    _stopTorrentStats();
    final stream = state.selectedStream;
    if (stream?.kind != StreamKind.torrent) return;
    if (!_servedHere(_engineUrl)) return;
    final request = TorrentStatsRequest.forStream(stream);
    if (request == null) return;
    _torrentStatsRequest = request;
    _reportPlayerOpened(request.infoHash);
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
  /// [_onMediaLoaded], [_onBuffering], the app going to the background and
  /// back, and every change of the stats OSD's visibility. Once the media has loaded a torrent's stats are worth
  /// asking for while playback is stalled (the stall card measures them)
  /// and, more slowly, while the OSD shows them -- playback being fine is
  /// no reason for a panel someone opened to freeze. Anything else -- no
  /// watcher, a backgrounded app, a direct stream, a failure that cleared
  /// the request -- leaves no timer behind.
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
      // Nobody wants numbers any more, but the cast check still wants the
      // name of the file the server opened, and a torrent that started
      // before the first poll came back has never been told one. This is
      // the one ask that would otherwise never happen: with no timer left
      // there is no later poll to carry it. Not while the app is in the
      // background, which asks the server for nothing at all; coming back
      // runs this again.
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
  /// Two things have to be true, and neither of them is "the player has a
  /// URL". It is [_engineUrl] rather than [_opened] because the URL the
  /// *engine* was handed is the one the bytes are cached under: for
  /// everything that is not a torrent [_mediaUrl] wraps the stream in this
  /// server's `/proxy` route, and the server reads the store to answer
  /// from off the path -- ask it with the core's bare origin URL and it
  /// recognises neither store, so the window of every proxied stream would
  /// be missing.
  ///
  /// And it has to be a stream this server is the one serving, which is
  /// [_servedHere] and is not this row's own rule: the sharing row of a
  /// film coming off somebody else's box would otherwise be this device's
  /// committed set and this device's ratio, read out of whatever engine it
  /// has for that info hash from a download or an earlier viewing.
  ///
  /// `buffer=` on the URL is left on: the server ignores every query key
  /// but `f=`, and stripping it would be a second idea of what the URL is.
  Uri? get _heldStreamUrl {
    final url = _engineUrl;
    return _servedHere(url) ? url : null;
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

  /// One ask, for [_heldStreamUrl] -- and nothing at all when there is no
  /// such URL, which is the case for a stream on somebody else's server.
  /// That decision lives here rather than in [_syncStreamNumbers] because
  /// what the engine was handed can change under an open panel (a re-open
  /// for a new buffer window), so it is read again for every ask; the
  /// timer above ticks either way and costs a returned call.
  ///
  /// An answer that comes back after the stream changed, or after the
  /// polling stopped, is not shown: it describes a moment nothing on
  /// screen is in any more. [_opened] is what says which video that was,
  /// not the URL asked with -- the URL is the address the bytes are held
  /// under and a re-open rewrites it without the film changing.
  ///
  /// Every failure is no rows. The server not running throws here and a
  /// stream it does not hold answers null; both mean there is nothing to
  /// draw, and neither is a fault of the playback the panel is over.
  Future<void> _pollStreamNumbers() async {
    final url = _heldStreamUrl;
    final playing = _opened;
    final reader = _streamNumbersReader;
    if (url == null || reader == null || _streamNumbersFetching) return;
    _streamNumbersFetching = true;
    StreamNumbers? numbers;
    try {
      numbers = await reader.streamNumbers(url);
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
