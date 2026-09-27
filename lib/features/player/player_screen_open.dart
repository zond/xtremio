part of 'player_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// Opening the stream: the URL the engine is handed, the read-ahead,
/// re-opens, containers, and retrying a slow torrent's start.
extension _PlayerOpen on _PlayerScreenState {
  /// Issues the engine's `open` for [url], with the start position the
  /// current stream was resolved with. Every failure goes through
  /// [_failPlayback], which decides whether it is worth another attempt --
  /// which is why a retry is this call again and nothing else.
  void _open(Uri url, {required String reason}) {
    final state = _openState;
    // Once: [_mediaUrl] reads the buffer window and the proxy token and
    // sets [_proxiedStream], and what is logged, opened and asked about
    // has to be the one URL rather than three answers that agree today.
    // [_translatedUrl] stands in front of the stream's own URL when the
    // stream turned out to be a container: what plays is the film inside
    // it, at a URL on our own server, and every later re-open is of that.
    final media = _mediaUrl(_translatedUrl ?? url);
    _engineUrl = media;
    _mediaIn = false;
    DiagnosticsLog.info(
      'player',
      'open ${DiagnosticsLog.url(media)} '
          'at ${_openStart.inSeconds}s ($reason)',
    );
    _engine
        ?.open(media, start: _openStart)
        .then((_) {
          if (state != null) _reportVideoParams(state, url);
          // A re-open is a fresh `loadfile` on the same player, and what
          // is in force belongs to the playback rather than to the file
          // the demuxer just re-read: the stream is re-opened on a
          // network error and on a buffer change, both keeping the
          // position, and a correction the viewer made ten minutes ago
          // has to survive that. Writing it again is what makes the
          // guarantee ours instead of a property mpv happens to carry
          // over; on a first open it re-states what [_onPlayerState] has
          // already put back. The file it was computed for goes back
          // first, because `loadfile` took that with it
          // ([_restoreExternalSubtitle]).
          if (_stillOurs && _opened == url) {
            _restoreExternalSubtitle();
            _applySubtitleTiming();
          }
        })
        .catchError((Object error) {
          if (!_stillOurs || _opened != url) return;
          DiagnosticsLog.error('player', 'open rejected: $error');
          _failPlayback('$error');
        });
  }

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

  /// Re-opens the stream at the position it is playing at, so a new
  /// `buffer=` takes effect without restarting the playback -- and only
  /// then.
  ///
  /// The window reaches libmpv through the URL and nowhere else, so a
  /// re-open that would hand it the URL it is already reading buys
  /// nothing and costs the picture: the demuxer starts again, the cache
  /// it had filled is dropped and the film stops for as long as the new
  /// read takes to come back. So a choice with the `buffer=` already in
  /// force ([BufferAhead.wholeFile] and [BufferAhead.maximum] share a
  /// wire) re-opens nothing, and nor does any choice on a stream the
  /// parameter is not written on ([_bufferOnUrlFor]).
  void _reopenForBuffer(String previousWire) {
    if (_bufferAhead.wire == previousWire || !_bufferOnUrlFor(_opened)) return;
    _reopenAt(_resumePosition, reason: 'reopen-buffer=${_bufferAhead.wire}');
  }

  /// [url] as the engine should fetch it, which is always a URL on our own
  /// server: the core's stream URL with `buffer=` added when it is a
  /// torrent the server is already serving, and the same stream wrapped in
  /// the server's `/proxy` route when it is anybody else's host.
  ///
  /// `buffer=` goes on the torrent alone. A remote host knows nothing about
  /// the parameter, and a kept download's URL -- this server's own media
  /// route, with every piece already on the device -- has nothing left to
  /// read ahead of; adding a query to either would be noise at best. A
  /// kept download falls through to the proxy check and is left alone
  /// there too, because it is a loopback URL.
  ///
  /// The proxy is the other half of having one cache instead of two
  /// ([proxiedThroughServer]). The player keeps nothing on disk now, so a
  /// stream it fetched itself would be the one kind of playback with no
  /// local copy anywhere -- and that was the kind that filled the owner's
  /// television.
  Uri _mediaUrl(Uri url) {
    if (!url.isScheme('http') && !url.isScheme('https')) return url;
    if (_bufferOnUrlFor(url)) return withBufferAhead(url, _bufferAhead);
    final proxied = proxiedThroughServer(
      url,
      serverBase: _serverBase,
      playerToken: _proxyToken,
    );
    // Recorded rather than inferred from the URL later, because a re-open
    // for a new buffer window, a next episode or a stream the core
    // resolved differently can each change what this answers -- and what
    // the teardown needs to know is whether *anything* was ever proxied
    // under this token, not what the last URL happened to be. The server
    // has to be ours for that to mean anything: with none there is nothing
    // to wrap, and a target host that happens to serve its own `/proxy`
    // path would otherwise read as one of ours.
    _proxiedStream |= _serverBase != null && isProxiedByServer(proxied);
    return proxied;
  }

  /// The viewer changed the buffer for this playback.
  ///
  /// The window itself only reaches the engine through the URL, and libmpv
  /// is already fetching the old one, so a change of window re-opens the
  /// stream at the position it is at -- one `open`, no reload of the
  /// player, no `Load Player`, and the core's own idea of the stream
  /// unchanged ([_opened] stays the URL the core published).
  /// [BufferAhead.wholeFile] additionally pins the stream as an offline
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

  /// Where a re-open of the stream on screen should start.
  ///
  /// [_position] only means something once the media is in: media_kit
  /// reports `position: 0` as soon as an `open` is issued, so a re-open
  /// while the start-up card is still up would otherwise throw away the
  /// position the playback was resumed at and start the film from the
  /// beginning.
  Duration get _resumePosition => _mediaLoaded ? _position.value : _openStart;

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
    // A re-open is an attempt at the playback, so whatever the last one
    // failed with is not what is happening any more: left, it sat as
    // "Playback failed" over a stream that was playing again, kept the
    // display's rate from being asked for ([_askDisplayFrameRate]) and
    // held the stats panel's request away.
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

  /// Whether [url] is one the buffer window is written on at all: the
  /// torrent half of [_mediaUrl]'s rule, asked on its own so that nothing
  /// re-opens a stream for a parameter that would not be there.
  bool _bufferOnUrlFor(Uri? url) {
    if (url == null || (!url.isScheme('http') && !url.isScheme('https'))) {
      return false;
    }
    // Not what is playing when the stream turned out to be a container
    // ([_translatedUrl]). The member is served by the archive routes, which
    // read no query but the session's own: the parameter would name
    // nothing there, and the read-ahead is the one the translator's source
    // opens on the torrent underneath it.
    if (_translatedUrl != null) return false;
    final stream = _state?.selectedStream ?? _state?.convertedStream;
    return stream?.infoHash != null;
  }

  /// Shows "Playback failed: [error]" in place of whatever was waiting for
  /// the media (the start-up overlay included, whose polling ends here) --
  /// unless the torrent is still starting up, in which case the open is
  /// simply tried again ([_scheduleOpenRetry]).
  void _failPlayback(String error) {
    if (_scheduleOpenRetry(error)) return;
    DiagnosticsLog.error('player', 'playback failed: $error');
    _cancelOpenRetry();
    // Nothing is being presented any more, and this screen stays up: the
    // card and every menu drawn over it would otherwise sit on a panel
    // held at the film's rate until the viewer pressed Back, which is the
    // juddering system UI this feature exists to avoid.
    _releaseDisplayFrameRate();
    // Which file of the torrent the server opened, read before the
    // failure forgets the torrent: [_stopTorrentStats] clears it, and it
    // is what names the container to the archive routes
    // ([_archiveRequest]).
    final fileInTorrent = _serverFilename ?? _torrentStats?.streamName;
    setState(() {
      _engineError = error;
      _stopTorrentStats();
    });
    final url = _engineUrl;
    // [_mediaIn], not [_mediaLoaded]: media_kit reports `playing: true`
    // the moment the `loadfile` is issued, before a byte has been read,
    // so on Android the other flag is true within a few hundred
    // milliseconds of every open and asked nothing of the container
    // playbacks this exists for. A film inside a RAR came back as mpv's
    // "Failed to recognize file format" on the television while every
    // test here passed, because a test's open fails at `open` and never
    // reports itself playing.
    if (!_mediaIn && url != null) {
      _explainArchive(url, error, fileInTorrent);
    }
  }

  /// Plays the film inside the source, when the source turned out to be a
  /// container rather than a film -- and says why not when it cannot.
  ///
  /// mpv's own words for a container are "Failed to recognize file format",
  /// which is true and useless: the source card rarely says what the file
  /// is, and the fix is not something the message suggests. The sniff
  /// names it ([archiveKindOf]); the server can then read the film inside
  /// it as ranges of the container itself, with nothing extracted and
  /// nothing written ([routeArchive]), and what plays is the member.
  ///
  /// **After the failure, not before it.** Sniffing before the first open
  /// would put a ranged read in front of every playback there is, and
  /// almost every playback is a film -- a round trip and 32 KiB (an ISO
  /// carries its signature at byte 32769) spent to learn nothing, on every
  /// title, on a television. Here it costs only the playbacks that were
  /// already going to fail, and it is truthful: nothing is taken away from
  /// mpv that mpv could open. What it costs is the wait for mpv to give
  /// up, which is the wait the message already had.
  ///
  /// Asked only of a stream whose file never showed up ([_mediaIn]), and
  /// only once the failure is final; the answer is dropped if another
  /// failure, or a new stream, has replaced this one by the time it
  /// comes.
  Future<void> _explainArchive(
    Uri url,
    String error,
    String? fileInTorrent,
  ) async {
    // Already the film inside a container: what failed is the member, and
    // sending a member round again would put the screen in a loop --
    // every answer to the sniff is the same answer, and every route of it
    // re-opens the same URL. One translation per stream.
    if (_translatedUrl != null) return;
    final kind = await _archiveSniff(url);
    if (kind == null || !_stillOurs || _engineError != error) return;
    DiagnosticsLog.info('player', 'the source is a ${kind.label}');
    final request = _archiveRequest(kind, url, fileInTorrent);
    final routed = request == null ? null : await _archiveRoute(request);
    if (!_stillOurs || _engineError != error) return;
    switch (routed) {
      case ArchiveMember(url: final member):
        DiagnosticsLog.info(
          'player',
          'the ${kind.label} holds ${DiagnosticsLog.url(member)}',
        );
        _translatedUrl = member;
        _reopenAt(_resumePosition, reason: 'archive-member');
      case ArchiveRefused():
        // The server's own sentence too, and this is the only place it
        // goes for a `noReader`: it names a cargo feature, which is for
        // whoever built the app and not for whoever is watching (see
        // [archiveRefusal]).
        DiagnosticsLog.warn(
          'player',
          'the server will not serve this ${kind.label}: '
              '${routed.kind} (${routed.message})',
        );
        setState(() => _engineError = archiveRefusal(kind, routed));
      case null:
        setState(() => _engineError = archiveFailure(kind));
    }
  }

  /// How the server is asked about the container this stream turned out to
  /// be, or null when there is nothing to ask with.
  ///
  /// A torrent's container is a file of a torrent the server already has,
  /// so it is named rather than fetched: the info hash and
  /// [fileInTorrent], the file's own name as the server states it
  /// ([_serverFilename], which is `streamName` from `stats.json` and is
  /// exactly the string the route matches on). Nothing else is a torrent, so it is named by the URL --
  /// [url], which is the URL the *engine* was handed and not the core's
  /// bare one: for anybody else's host that is this server's `/proxy` URL,
  /// carrying the stream's credentials, and a container the server cannot
  /// fetch is a container it cannot index.
  ArchiveRouteRequest? _archiveRequest(
    ArchiveKind kind,
    Uri url,
    String? fileInTorrent,
  ) {
    final base = _serverBase;
    if (base == null) return null;
    final stream = _openState?.selectedStream;
    if (stream?.kind == StreamKind.torrent) {
      final infoHash = stream?.infoHash;
      // Which file of the torrent this is comes from the server's own
      // stats, and a torrent it has not answered about yet is one nothing
      // here can name a file of.
      if (infoHash == null || fileInTorrent == null) return null;
      return ArchiveRouteRequest.inTorrent(
        serverBase: base,
        kind: kind,
        infoHash: infoHash,
        pathInTorrent: fileInTorrent,
      );
    }
    return ArchiveRouteRequest.link(serverBase: base, kind: kind, played: url);
  }

  // --- Retrying a slow torrent's open --------------------------------------

  /// Whether a failed `open` is worth another attempt.
  ///
  /// Only for a torrent, only before the media has loaded, and only while
  /// the server says the torrent is not ready yet -- still resolving its
  /// metadata, hash-checking, or filling the initial window -- or has not
  /// answered about it at all, which is where a start-up spends its first
  /// seconds. mpv gives up on the first refusal; the server, at that
  /// moment, has nothing to serve yet and is perfectly entitled to say so.
  ///
  /// The kind of stream being played is what decides it, and not whether
  /// this screen is polling for stats: a torrent on a streaming server on
  /// another machine is one this device asks nothing about
  /// ([_startTorrentStats]) and whose start-up is just as slow, so it gets
  /// the same patience with no stats to consult -- the bounded retries
  /// alone.
  ///
  /// A direct HTTP stream, a torrent the server has given up on
  /// ([TorrentPhase.error]), a phase we do not recognise, and a `ready`
  /// torrent that still would not open are all real failures: nothing about
  /// them will be different in a second.
  bool get _retryableTorrentStart {
    if (!mounted || _handedOver || _mediaLoaded) return false;
    if (_openState?.selectedStream?.kind != StreamKind.torrent) return false;
    final stats = _torrentStats;
    if (stats == null) return true;
    return switch (stats.phase) {
      TorrentPhase.resolvingMetadata ||
      TorrentPhase.checking ||
      TorrentPhase.buffering => true,
      TorrentPhase.ready || TorrentPhase.error || TorrentPhase.unknown => false,
    };
  }

  /// Answers [error] with another attempt instead of a failure, and says so.
  ///
  /// The start-up card stays up untouched meanwhile -- the poller behind it
  /// was never stopped -- so what the user sees is the torrent still
  /// starting, which is exactly what is happening. At most one attempt is
  /// ever waiting: `open`'s rejection and the engine's error stream both
  /// land here for the same failure.
  bool _scheduleOpenRetry(String error) {
    if (!_retryableTorrentStart ||
        _openRetries >= PlayerScreen.torrentOpenRetries) {
      return false;
    }
    _openError = error;
    if (_openRetryTimer != null) return true;
    _openRetries++;
    DiagnosticsLog.warn(
      'player',
      'open refused while the torrent is ${_torrentStats?.phase.name ?? 'starting'}; '
          'retry $_openRetries of ${PlayerScreen.torrentOpenRetries}',
    );
    _openRetryTimer = Timer(
      PlayerScreen.torrentOpenRetryBackoff * _openRetries,
      _retryOpen,
    );
    return true;
  }

  void _retryOpen() {
    _openRetryTimer = null;
    final url = _opened;
    if (!mounted || _handedOver || url == null) return;
    // The wait is also how the server gets to change its mind: a torrent
    // that failed while we were being patient is a failure after all.
    if (!_retryableTorrentStart) {
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
