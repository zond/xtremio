part of 'player_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// Opening the stream: what the engine is handed (a media id, as a rule),
/// the read-ahead, re-opens, and retrying a slow torrent's start.
extension _PlayerOpen on _PlayerScreenState {
  /// Issues the engine's `open` for [url], with the start position the
  /// current stream was resolved with. Every failure goes through
  /// [_failPlayback], which decides whether it is worth another attempt --
  /// which is why a retry is this call again and nothing else.
  ///
  /// **What the engine is handed is decided by the server**, not by the
  /// URL's shape: the stream is registered as a media id ([_register]),
  /// resolved ([_playable]), and mpv reads `xtremio://<id>` -- unless the
  /// server says it reads it only forward, over HTTP.
  void _open(Uri url, {required String reason}) {
    final state = _openState;
    final attempt = ++_openAttempt;
    _mediaIn = false;
    // A position reported before this open is not this file's; until one
    // is, a seek has to be held ([_seekEngineTo]). And a seek held for the
    // last open is not this one's: this open starts at it already
    // ([_openStart]) when it was the viewer's, and a new stream is not
    // where they sought at all.
    _reportedPosition = null;
    _letHeldSeekGo();
    final start = _openStart;
    final FutureOr<String?> registering;
    try {
      registering = _register(url);
    } catch (error) {
      DiagnosticsLog.error('player', 'could not register the stream: $error');
      _failPlayback('$error');
      return;
    }
    final engine = _engine;
    if (engine == null) return;
    Future.value(registering)
        .then((id) => _playable(url, id))
        .then((media) {
          // Resolving can take as long as a magnet's metadata does, and
          // the viewer may have left or moved on meanwhile.
          if (media == null || !_stillOurs || attempt != _openAttempt) {
            return null;
          }
          _engineUrl = media;
          DiagnosticsLog.info(
            'player',
            'open ${DiagnosticsLog.url(media)} '
                'at ${start.inSeconds}s ($reason)',
          );
          final opening = engine.open(media, start: start);
          // After the open is on its way, as a torrent read by URL reports
          // it after its stream request ([_startTorrentStats]).
          if (mediaIdOf(media) case final id?) _reportMediaOpened(id);
          return opening.then((_) {
            if (state != null) _reportVideoParams(state, url);
            // A re-open is a fresh `loadfile`, and a correction the viewer
            // made belongs to the playback, not to the file re-read: write
            // it again so it survives a re-open for a network error. The
            // addon file goes back first, because `loadfile` dropped it
            // ([_restoreExternalSubtitle]).
            if (_stillOurs && _opened == url) {
              _restoreExternalSubtitle();
              _applySubtitleTiming();
            }
          });
        })
        .catchError((Object error) {
          if (!_stillOurs || _opened != url || attempt != _openAttempt) return;
          DiagnosticsLog.error('player', 'open rejected: $error');
          _failPlayback(
            '$error',
            waitingForBytes: _isWaitingForBytes(error),
            answered: error is MediaRefusal && !_isWaitingForBytes(error),
          );
        });
  }

  /// **Every stream is registered with the embedded server as a media id**,
  /// whatever it is, and answers that id -- or null for one nothing here
  /// can name, which the engine is handed as it is.
  ///
  /// - A URL on the embedded server -- a torrent, a `/proxy` link the core
  ///   built, an archive member's `/{fmt}/create`, a kept torrent download
  ///   -- as it is ([MediaIds.register]).
  /// - A link on anybody else's host, wrapped in the server's `/proxy`
  ///   first ([proxiedThroughServer], with this screen's player token):
  ///   the server's proxy cache is the one cache on this device, and the
  ///   token is what ends a link read forward over HTTP when the screen
  ///   goes ([_closeProxiedStreams]).
  /// - A linked Drive file, `xtremio-drive:<fileId>` ([MediaIds.registerDrive]).
  /// - A file on this device: a `file://` path, or a `content://` document
  ///   whose descriptor is handed over ([MediaIds.registerLocalContent]).
  ///
  /// The play goes with the id ([MediaIds.setPlay]): this screen's player
  /// token, which makes the reads the viewer's playback, and the buffer
  /// window, which a later change moves by [MediaIds.setBuffer]
  /// ([_reopenForBuffer]). Kept across re-opens of the same stream -- a
  /// retry, a false end -- so the server's answer about it is found again
  /// rather than asked again; a different stream registers anew.
  ///
  /// Nothing in a build that started no embedded server ([_serverBase]).
  FutureOr<String?> _register(Uri url) {
    final ids = _mediaIds;
    final base = _serverBase;
    if (ids == null || base == null) return null;
    if (mediaIdOf(url) case final id?) return id;
    final known = _mediaId;
    if (_mediaIdSource == url && known != null) {
      _setPlay(known);
      return known;
    }
    final name =
        (_openState?.selectedStream ?? StreamInfo(widget.stream)).filename;
    final FutureOr<String> id;
    if (url.isScheme(driveSourceScheme)) {
      id = ids.registerDrive(url.path, name: name);
    } else if (url.isScheme('file')) {
      id = ids.registerLocalPath(url.toFilePath(), name: name);
    } else if (url.isScheme('content')) {
      id = ids.registerLocalContent(url, name: name);
    } else if (url.isScheme('http') || url.isScheme('https')) {
      id = ids.register(
        isEmbeddedServerHost(url.host)
            ? url
            : proxiedThroughServer(
                url,
                serverBase: base,
                playerToken: _proxyToken,
              ),
      );
    } else {
      return null;
    }
    String remember(String id) {
      _mediaId = id;
      _mediaIdSource = url;
      _setPlay(id);
      return id;
    }

    return id is String ? remember(id) : id.then(remember);
  }

  void _setPlay(String id) =>
      _mediaIds?.setPlay(id, token: _proxyToken, buffer: _bufferAhead.wire);

  /// What the engine is to be handed for [url], registered as [id]: has the
  /// server resolve it first, and answers `xtremio://<id>` for anything
  /// read in process, the server's `/proxy` URL for an origin it reads only
  /// forward, and [url] itself when there is no id. Null when this screen
  /// has moved on meanwhile.
  ///
  /// **Here, and not in mpv's open.** Resolving a magnet waits for its
  /// metadata, up to the server's metadata timeout, and a `stream_cb` open
  /// cannot be cancelled -- mpv's core thread would sit in it through a
  /// quit. Done here, it is a wait on a worker that the screen can walk
  /// away from, and the reader mpv opens afterwards finds the answer
  /// kept. A refusal is the server's own sentence, and fails the playback
  /// the way a refused `open` does ([_failPlayback], which retries a
  /// torrent still starting).
  ///
  /// The server's sniff is what finds a container: a `.rar` or an `.iso`
  /// resolves to the film inside it ([MediaResolution.memberName]), and
  /// mpv reads the film.
  Future<Uri?> _playable(Uri url, String? id) async {
    final ids = _mediaIds;
    if (id == null || ids == null) return url;
    var resolution = await ids.resolve(id);
    if (resolution.refusal?.kind == 'unknownId' && _mediaIdSource == url) {
      // The server let the id go (a restart, the cap): registered again,
      // once.
      _mediaIdSource = null;
      final again = await _register(url);
      if (again == null) return url;
      id = again;
      resolution = await ids.resolve(again);
    }
    if (!_stillOurs) return null;
    final refusal = resolution.refusal;
    if (refusal != null) {
      if (_servedOnlyByRoute(url, refusal)) return url;
      DiagnosticsLog.warn(
        'player',
        'the server will not play it: ${refusal.kind}',
      );
      throw refusal;
    }
    _mediaResolution = resolution;
    if (!resolution.inProcess) {
      final proxied = resolution.proxyUrl;
      if (proxied == null) {
        throw const MediaRefusal(
          'noRanges',
          'This stream can only be read forward, and nothing here can.',
        );
      }
      _proxiedStream |= isProxiedByServer(proxied);
      return proxied;
    }
    return mediaIdUrl(id);
  }

  /// Whether [url] is one of the embedded server's own routes that it
  /// serves over HTTP and not by id yet -- an `/ftp` link, a YouTube
  /// stream, anything it does not recognise -- which the engine is then
  /// handed as it is, as before ids.
  bool _servedOnlyByRoute(Uri url, MediaRefusal refusal) =>
      (url.isScheme('http') || url.isScheme('https')) &&
      isEmbeddedServerHost(url.host) &&
      (refusal.kind == 'notYet' || refusal.kind == 'unrecognisedUrl');

  /// How far ahead this playback buffers: the viewer's override for the
  /// playback on screen, else the app-wide default.
  BufferAhead get _bufferAhead =>
      _bufferOverride ?? _prefs?.bufferAhead ?? BufferAhead.normal;

  /// Republishes what the settings sheet shows about the buffer.
  void _publishBuffer() {
    _bufferStatus.value = BufferAheadStatus(
      _bufferAhead,
      busy: _keeping,
      note: _bufferNote,
    );
  }

  /// Puts a new buffer choice in force for the stream on screen.
  ///
  /// A stream played by id ([_register]) is told through the server
  /// ([MediaIds.setBuffer]), which the reader takes at its next seek:
  /// nothing is re-opened, and the film does not stop. A stream read over
  /// HTTP has no read-ahead of ours to change, and is left alone.
  void _reopenForBuffer(String previousWire) {
    if (_bufferAhead.wire == previousWire) return;
    final id = _playingMediaId;
    if (id == null) return;
    try {
      _mediaIds?.setBuffer(id, _bufferAhead.wire);
    } catch (error) {
      // The next open carries it regardless ([MediaIds.setPlay]).
      DiagnosticsLog.warn('player', 'buffer change not taken: $error');
    }
  }

  /// The media id the engine is reading, or null when it is reading a URL.
  String? get _playingMediaId => mediaIdOf(_engineUrl);

  /// The media id the stream on screen ([_opened]) was registered as, from
  /// the moment it was -- before the server has answered and the engine has
  /// it, which [_playingMediaId] waits for. Null for a stream with no id.
  String? get _registeredMediaId => _mediaIdSource == _opened ? _mediaId : null;

  /// The viewer changed the buffer for this playback.
  ///
  /// A stream played by id is told so through the server and nothing
  /// re-opens ([_reopenForBuffer]). [BufferAhead.wholeFile] additionally pins the stream as an offline
  /// download; the pin is what stores the file, so it outlives this
  /// playback and is deleted from the Downloads screen like any other.
  void _setBufferAhead(BufferAhead choice) {
    if (choice == _bufferAhead) return;
    final previousWire = _bufferAhead.wire;
    setState(() {
      _bufferOverride = choice;
      _bufferNote = choice.storesTheFile
          ? 'Keeping this file on the device. It will appear in Downloads.'
          : null;
      _publishBuffer();
    });
    _reopenForBuffer(previousWire);
    if (choice.storesTheFile) unawaited(_keepWholeFile());
  }

  /// Re-opens the stream at [start] on the same engine -- no `Load Player`,
  /// no new route, and the core's idea of the stream untouched.
  void _reopenAt(Duration start, {required String reason}) {
    final url = _opened;
    if (url == null || _leaving || _handedOver || _casting) return;
    _cancelOpenRetry();
    _openStart = start;
    _openRetries = 0;
    _openError = null;
    // The window that follows is filling, which is not the stall the
    // server is told about; see [_playingNormally].
    _playingNormally = false;
    _playedSinceSeek = Duration.zero;
    // A re-open is a new attempt, so the last failure is not what is
    // happening any more: left, it would sit as "Playback failed" over a
    // stream that plays, block the display's rate ([_askDisplayFrameRate])
    // and hold the stats panel's request away.
    final failed = _engineError != null;
    if (failed) setState(() => _engineError = null);
    _open(url, reason: reason);
    if (failed) _restoreTorrentStats();
  }

  /// Pins what is playing as an offline download, which is what
  /// [BufferAhead.wholeFile] is: the existing mechanism, not a second one.
  ///
  /// A refusal is shown rather than swallowed -- a device that cannot fit
  /// the file is told so, with the numbers the server refused on -- and the
  /// choice falls back to the widest window that needs no room.
  Future<void> _keepWholeFile() async {
    final client = DownloadsScope.maybeOf(context);
    final state = _state;
    final stream = state?.selectedStream;
    final meta = state?.metaItem?.contentOrNull;
    if (client == null || state == null || stream == null || meta == null) {
      _failBuffer('This stream cannot be kept on the device.');
      return;
    }
    final videoId = state.selectedVideoId ?? meta.id;
    setState(() {
      _keeping = true;
      _publishBuffer();
    });
    DownloadAddResult? result;
    Object? thrown;
    try {
      result = await client.add(
        DownloadRequest(
          metaId: meta.id,
          videoId: videoId,
          type: meta.type,
          name: downloadName(meta, meta.videoById(videoId)),
          poster: meta.poster,
          stream: stream,
          meta: meta.json,
          streamRequest: state.streamRequest?.toJson(),
          metaRequest: state.metaRequest?.toJson(),
        ),
      );
    } catch (error) {
      thrown = error;
    }
    // The registry took a round trip to answer and a refusal re-opens the
    // stream ([_failBuffer]), so this is a way back onto the engine.
    if (!_stillOurs) return;
    setState(() {
      _keeping = false;
      _publishBuffer();
    });
    if (thrown != null) {
      _failBuffer('This stream could not be kept on the device.');
      return;
    }
    final failure = result!.error;
    if (failure != null) {
      _failBuffer(downloadFailureMessage(failure));
      return;
    }
    setState(() {
      _bufferNote =
          'Keeping this file on the device. It is in Downloads, where it '
          'can be deleted.';
      _publishBuffer();
    });
  }

  /// The file cannot be kept: say why, and buffer as far ahead as the
  /// server will instead, which is the most that can be done without room
  /// on the disk.
  void _failBuffer(String reason) {
    if (!_stillOurs) return;
    final previousWire = _bufferAhead.wire;
    setState(() {
      _bufferOverride = BufferAhead.maximum;
      _keeping = false;
      _bufferNote = '$reason Buffering as far ahead as possible instead.';
      _publishBuffer();
    });
    _reopenForBuffer(previousWire);
  }

  /// Tells the engine what it can know about the file, which is what makes
  /// it ask the subtitle addons (they want a filename, hash or size; we
  /// have at best the filename). Without a real one, none is sent: the
  /// engine asks the addons anyway from its converted stream, and a
  /// stand-in such as the stream's label ("1080p") would only mislead the
  /// filename matching at OpenSubtitles.
  void _reportVideoParams(PlayerState state, Uri url) {
    if (!_stillOurs || _handedOver || _opened != url) return;
    final segment = url.pathSegments.isEmpty ? null : url.pathSegments.last;
    final filename =
        state.convertedStream?.filename ??
        state.selectedStream?.filename ??
        (segment != null && segment.contains('.') ? segment : null);
    _client?.dispatch(CoreActions.playerVideoParamsChanged(filename: filename));
  }

  /// Whether a refusal from the server is a wait for bytes rather than an
  /// answer: a torrent whose metadata did not come in time
  /// (`torrentUnavailable`, which the server keeps for a swarm that has not
  /// answered). Every other refusal -- a torrent the backend refused
  /// (`torrentRefused`), no such file, not a URL it serves, a pipe it
  /// cannot seek, a pairing that is gone, an origin that refused -- says
  /// the stream cannot be played.
  static bool _isWaitingForBytes(Object error) =>
      error is MediaRefusal && error.kind == 'torrentUnavailable';

  /// Shows "Playback failed: [error]" in place of whatever was waiting for
  /// the media (the start-up overlay included, whose polling ends here) --
  /// unless the torrent is still starting up, or the server is waiting for
  /// its bytes ([waitingForBytes]), in which case the open is simply tried
  /// again ([_scheduleOpenRetry]), for as long as the viewer stays.
  ///
  /// [answered] is a refusal from the server that says the stream cannot be
  /// played: it is shown at once, whatever phase the torrent is in.
  void _failPlayback(
    String error, {
    bool waitingForBytes = false,
    bool answered = false,
  }) {
    if (!answered &&
        _scheduleOpenRetry(error, waitingForBytes: waitingForBytes)) {
      return;
    }
    DiagnosticsLog.error('player', 'playback failed: $error');
    _cancelOpenRetry();
    // Nothing is being presented any more, and this screen stays up: the
    // card and every menu drawn over it would otherwise sit on a panel
    // held at the film's rate until the viewer pressed Back, which is the
    // juddering system UI this feature exists to avoid.
    _releaseDisplayFrameRate();
    setState(() {
      _engineError = error;
      _stopTorrentStats();
    });
  }

  // --- Retrying a slow torrent's open --------------------------------------

  /// Whether a failed `open` is worth another attempt.
  ///
  /// Only for a torrent, only before the media has loaded, and only while
  /// the server says the torrent is not ready yet (resolving metadata,
  /// checking, filling the initial window) or has not answered at all: mpv
  /// gives up on the first refusal, when the server has nothing to serve
  /// yet.
  ///
  /// A torrent in `error` is one whose metadata did not come in time -- a
  /// dead swarm, which is waited for. A direct HTTP stream, an unknown
  /// phase, and a `ready` torrent that still would not open are real
  /// failures.
  bool get _retryableTorrentStart {
    if (!_torrentStarting) return false;
    final stats = _torrentStats;
    if (stats == null) return true;
    return switch (stats.phase) {
      TorrentPhase.resolvingMetadata ||
      TorrentPhase.checking ||
      TorrentPhase.buffering ||
      TorrentPhase.error => true,
      TorrentPhase.ready || TorrentPhase.unknown => false,
    };
  }

  /// A torrent on screen whose media has not come in yet.
  bool get _torrentStarting =>
      mounted &&
      !_handedOver &&
      !_mediaLoaded &&
      _openState?.selectedStream?.kind == StreamKind.torrent;

  /// Answers [error] with another attempt instead of a failure, and says so.
  ///
  /// The start-up card stays up untouched meanwhile -- the poller behind it
  /// was never stopped -- so what the user sees is the torrent still
  /// starting, which is exactly what is happening. At most one attempt is
  /// ever waiting: `open`'s rejection and the engine's error stream both
  /// land here for the same failure.
  bool _scheduleOpenRetry(String error, {bool waitingForBytes = false}) {
    final waits = waitingForBytes ? _torrentStarting : _retryableTorrentStart;
    if (!waits) return false;
    _openError = error;
    _openWaitingForBytes = waitingForBytes;
    if (_openRetryTimer != null) return true;
    _openRetries++;
    final wait = PlayerScreen.retryWait(_openRetries);
    DiagnosticsLog.warn(
      'player',
      'open refused while the torrent is ${_torrentStats?.phase.name ?? 'starting'}; '
          'retry $_openRetries in ${wait.inMilliseconds}ms',
    );
    _openRetryTimer = Timer(wait, _retryOpen);
    return true;
  }

  void _retryOpen() {
    _openRetryTimer = null;
    final url = _opened;
    if (!mounted || _handedOver || url == null) return;
    // The wait is also how the server gets to change its mind: a torrent
    // that turned out ready and still would not open is a failure after
    // all.
    final waits = _openWaitingForBytes
        ? _torrentStarting
        : _retryableTorrentStart;
    if (!waits) {
      _failPlayback(_openError ?? 'the torrent could not be opened');
      return;
    }
    _open(url, reason: 'retry $_openRetries');
  }

  void _cancelOpenRetry() {
    _openRetryTimer?.cancel();
    _openRetryTimer = null;
  }
}
