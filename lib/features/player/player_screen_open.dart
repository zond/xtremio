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
    final Uri media;
    try {
      media = _mediaUrl(_translatedUrl ?? url);
    } catch (error) {
      DiagnosticsLog.error('player', 'could not register the stream: $error');
      _failPlayback('$error');
      return;
    }
    _engineUrl = media;
    _mediaIn = false;
    final start = _openStart;
    DiagnosticsLog.info(
      'player',
      'open ${DiagnosticsLog.url(media)} '
          'at ${start.inSeconds}s ($reason)',
    );
    final engine = _engine;
    if (engine == null) return;
    _resolveMedia(media)
        .then((resolved) {
          // Resolving can take as long as a magnet's metadata does, and
          // the viewer may have left or moved on meanwhile.
          if (!resolved || !_stillOurs || _engineUrl != media) return null;
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
          if (!_stillOurs || _opened != url) return;
          DiagnosticsLog.error('player', 'open rejected: $error');
          _failPlayback('$error');
        });
  }

  /// Has the server resolve [media] before mpv is handed it, when it is a
  /// media id; answers whether it is still the one to open. Nothing to do
  /// for a URL.
  ///
  /// **Here, and not in mpv's open.** Resolving a magnet waits for its
  /// metadata, up to the server's metadata timeout, and a `stream_cb` open
  /// cannot be cancelled -- mpv's core thread would sit in it through a
  /// quit. Done here, it is a wait on a worker that the screen can walk
  /// away from, and the reader mpv opens afterwards finds the answer
  /// kept. A refusal is the server's own sentence, and fails the playback
  /// the way a refused `open` does ([_failPlayback], which retries a
  /// torrent still starting).
  Future<bool> _resolveMedia(Uri media) async {
    final id = mediaIdOf(media);
    final ids = _mediaIds;
    if (id == null || ids == null) return true;
    final refusal = await ids.resolve(id);
    if (refusal != null) {
      DiagnosticsLog.warn(
        'player',
        'the server will not play it: ${refusal.kind}',
      );
      // An id the server let go (a restart, the cap) is registered again
      // at the next attempt.
      if (refusal.kind == 'unknownId' && _mediaId == id) _mediaIdSource = null;
      throw refusal;
    }
    return true;
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

  /// Puts a new buffer choice in force for the stream on screen.
  ///
  /// A torrent played by id ([_mediaUrl]) is told through the server
  /// ([MediaIds.setBuffer]), which the reader takes at its next seek:
  /// nothing is re-opened, and the film does not stop.
  ///
  /// Anything else carrying `buffer=` on its URL ([_bufferOnUrlFor]) is
  /// re-opened at the position it is playing at, so the new parameter takes
  /// effect -- and only then. A re-open drops the demuxer's cache and stops
  /// the film for as long as the new read takes, so a choice with the
  /// `buffer=` already in force ([BufferAhead.wholeFile] and
  /// [BufferAhead.maximum] share a wire), or a stream without the
  /// parameter, re-opens nothing.
  void _reopenForBuffer(String previousWire) {
    if (_bufferAhead.wire == previousWire) return;
    final id = mediaIdOf(_engineUrl);
    if (id != null) {
      try {
        _mediaIds?.setBuffer(id, _bufferAhead.wire);
      } catch (error) {
        // The next open carries it regardless ([MediaIds.setPlay]).
        DiagnosticsLog.warn('player', 'buffer change not taken: $error');
      }
      return;
    }
    if (!_bufferOnUrlFor(_opened)) return;
    _reopenAt(_resumePosition, reason: 'reopen-buffer=${_bufferAhead.wire}');
  }

  /// [url] as the engine should fetch it.
  ///
  /// **A torrent is played by id**: registered with the embedded server
  /// ([MediaIds.register]) and handed to the engine as `xtremio://<id>`,
  /// which libmpv reads through the server's reader and not over HTTP
  /// ([mediaIdScheme]). What the torrent's URL used to carry for the server
  /// goes with the id instead: this screen's player token ([_proxyToken],
  /// `p=`), which makes the reads the viewer's play session, and the buffer
  /// window (`buffer=`), both by [MediaIds.setPlay] -- and a later buffer
  /// change by [MediaIds.setBuffer] ([_reopenForBuffer]).
  ///
  /// Only in a build with an embedded server ([_serverBase]); every other
  /// stream is a URL on our own server as before: the same stream wrapped
  /// in the server's `/proxy` route when it is anybody else's host, and a
  /// loopback URL (a kept download, an archive member) left alone. The
  /// proxy makes the server's cache the only one
  /// ([proxiedThroughServer]); the player keeps nothing on disk.
  Uri _mediaUrl(Uri url) {
    if (!url.isScheme('http') && !url.isScheme('https')) return url;
    final ids = _mediaIds;
    if (_bufferOnUrlFor(url) && _serverBase != null && ids != null) {
      if (_mediaIdSource != url || _mediaId == null) {
        _mediaId = ids.register(url);
        _mediaIdSource = url;
      }
      final id = _mediaId!;
      ids.setPlay(id, token: _proxyToken, buffer: _bufferAhead.wire);
      return mediaIdUrl(id);
    }
    if (_bufferOnUrlFor(url)) {
      return withPlayerToken(withBufferAhead(url, _bufferAhead), _proxyToken);
    }
    final proxied = proxiedThroughServer(
      url,
      serverBase: _serverBase,
      playerToken: _proxyToken,
    );
    // Recorded, not inferred later: a re-open, a next episode or a stream
    // the core resolved differently can each change this answer, and the
    // teardown needs to know whether *anything* was proxied under this
    // token. Only with a server of ours: a host that serves its own `/proxy`
    // path would otherwise read as one of ours.
    _proxiedStream |= _serverBase != null && isProxiedByServer(proxied);
    return proxied;
  }

  /// The media id the engine is reading, or null when it is reading a URL.
  String? get _playingMediaId => mediaIdOf(_engineUrl);

  /// The URL the start of a stream that failed is read through, to tell an
  /// archive from a film ([_explainArchive]): the engine's own URL, or for
  /// a torrent played by id the torrent's stream URL on the server, as it
  /// was handed the engine before ids.
  Uri? get _sniffUrl {
    final url = _engineUrl;
    if (mediaIdOf(url) == null) return url;
    final source = _mediaIdSource;
    if (source == null) return null;
    return withPlayerToken(withBufferAhead(source, _bufferAhead), _proxyToken);
  }

  /// The viewer changed the buffer for this playback.
  ///
  /// A torrent played by id is told so through the server and nothing
  /// re-opens ([_reopenForBuffer]). Where the window reaches the engine
  /// only through the URL, which libmpv is already fetching, a change of
  /// window re-opens the stream at the position it is at -- one `open`, no
  /// reload of the player, no `Load Player`, and the core's own idea of the
  /// stream unchanged ([_opened] stays the URL the core published).
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
    final url = _sniffUrl;
    // [_mediaIn], not [_mediaLoaded]: media_kit reports `playing: true` when
    // the `loadfile` is issued, before a byte is read, so [_mediaLoaded] is
    // true within a few hundred milliseconds of every open on Android and
    // would skip every container this is for.
    if (!_mediaIn && url != null) {
      _explainArchive(url, error, fileInTorrent);
    }
  }

  /// Plays the film inside the source when the source turned out to be a
  /// container rather than a film, and says why not when it cannot.
  ///
  /// mpv's words for a container are "Failed to recognize file format". The
  /// sniff names it ([archiveKindOf]); the server can then read the film
  /// inside as ranges of the container, with nothing extracted or written
  /// ([routeArchive]), and what plays is the member.
  ///
  /// **After the failure, not before it.** Sniffing before the first open
  /// would put a ranged read (32 KiB: an ISO's signature is at byte 32769)
  /// in front of every playback, almost all of which are films. Here it
  /// costs only playbacks that were already failing, and takes nothing from
  /// mpv that mpv could open.
  ///
  /// Asked only of a stream whose file never showed up ([_mediaIn]), once
  /// the failure is final; the answer is dropped if another failure or a new
  /// stream has replaced this one.
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
  /// A torrent's container is a file of a torrent the server already has, so
  /// it is named rather than fetched: the info hash and [fileInTorrent], the
  /// file's name as the server states it ([_serverFilename], `streamName`
  /// from `stats.json`). Anything else is named by [url], the URL the
  /// *engine* was handed: for another host that is this server's `/proxy`
  /// URL, carrying the stream's credentials.
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
  /// the server says the torrent is not ready yet (resolving metadata,
  /// checking, filling the initial window) or has not answered at all: mpv
  /// gives up on the first refusal, when the server has nothing to serve
  /// yet.
  ///
  /// A direct HTTP stream, a torrent the server has given up on, an unknown
  /// phase, and a `ready` torrent that still would not open are real
  /// failures.
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
