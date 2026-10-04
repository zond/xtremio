part of 'player_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// Casting: the receiver sheet, handing the stream to a receiver, and
/// bringing it back.
extension _PlayerCasting on _PlayerScreenState {
  // --- Casting -------------------------------------------------------------

  /// Takes the sender and the LAN media listener from the scope and starts
  /// looking for receivers, once, when the screen comes up.
  ///
  /// Discovery costs radio and battery, so it runs while a player is open
  /// and not for the life of the app; [dispose] stops it. A television
  /// starts none of it: a TV *is* a receiver, and the button that would
  /// open this is never built there.
  void _wireCast(CastClient client, LanMediaControl lanMedia) {
    _cast = client;
    _lanMedia = lanMedia;
    if (_isTv || !client.isSupported) return;
    _castDeviceList.value = client.currentDevices;
    _subscriptions.addAll([
      client.devices.listen(_onCastDevices),
      client.session.listen(_onCastSession),
      client.status.listen(_onCastStatus),
    ]);
    client.startDiscovery().ignore();
  }

  /// Whether there is anything to cast to, which is the whole condition for
  /// the button being on the bar: a sender platform, not a television, and
  /// a receiver that has actually answered.
  bool get _castAvailable =>
      !_isTv &&
      (_cast?.isSupported ?? false) &&
      (_castDevices.isNotEmpty || _casting);

  void _onCastDevices(List<CastDevice> devices) {
    if (!mounted) return;
    setState(() => _castDeviceList.value = devices);
  }

  /// The session as the sender sees it. A null while this screen thinks it
  /// is casting means the session ended elsewhere (the receiver's remote,
  /// the system notification, another phone), and playback comes back here
  /// as if Stop had been pressed.
  ///
  /// **Not while a receiver is being picked in its place** ([_castStarts]):
  /// starting a session ends the running one, and taking that report for a
  /// Stop would close the listener the new session is being handed. A
  /// session on some *other* receiver, reported with no switch under way
  /// (the system's output switcher, say), is the same ending and gets the
  /// same answer.
  void _onCastSession(CastDevice? device) {
    if (!mounted || !_casting || _castStarts > 0) return;
    if (device != null && device == _castingTo) return;
    unawaited(_stopCast(disconnect: false));
  }

  /// What the receiver reports: what is drawn, and what the core is told.
  ///
  /// The same three actions local playback dispatches -- `TimeChanged`,
  /// `PausedChanged`, `Ended` -- so the library and continue-watching do not
  /// notice which device the pixels were on.
  void _onCastStatus(CastStatus reported) {
    if (!mounted) return;
    final status = _casting ? _trustedCastStatus(reported) : reported;
    setState(() => _castStatus = status);
    if (!_casting || _opened == null) return;
    final duration = status.duration;
    // Once per length, not per status: a receiver repeats its status every
    // second or so, and a length does not go stale.
    if (duration != null && duration > Duration.zero && duration != _duration) {
      _duration = duration;
      // **All a cast can tell the server.** The receiver's position is in
      // seconds, which do not convert to a byte offset without a constant
      // bitrate (a 2% error on a 23 GB film is wider than the retention
      // window); the length does give the bitrate, so the window is sized
      // exactly and placed by the receiver's own sequential reads.
      unawaited(_reportDuration(duration));
    }
    _position.value = status.position;
    _reportTime(status.position);
    _reportPlaying(status.state.isPlaying);
    // A receiver keeps repeating "idle, finished"; the core hears it once.
    //
    // Casts do not binge, by decision: no up-next card and no hand-over,
    // whatever `bingeWatching` says. The countdown assumes someone at this
    // screen who can press Cancel, and a television that plays on into the
    // next episodes by itself is what to avoid.
    if (status.ended && !_castEnded) {
      _castEnded = true;
      _client?.dispatch(CoreActions.playerEnded());
    }
  }

  /// [reported] as it is to be believed: with a zero the receiver has not
  /// actually reported replaced by the position it was handed (see
  /// [_castHandedAt]). The first position that is not zero is the
  /// receiver's own tick, and from then on every report is its own --
  /// including a later zero, which is then a receiver really at the start.
  CastStatus _trustedCastStatus(CastStatus reported) {
    if (_castReported) return reported;
    if (reported.position != Duration.zero) {
      _castReported = true;
      return reported;
    }
    return reported.at(_castHandedAt);
  }

  /// The receivers, and Stop when one of them has the stream.
  ///
  /// mpv is sampled while the sheet is up, because the compatibility check
  /// would rather hear what the decoder is actually reading than what the
  /// release name claims. The subscription is what makes the engine sample
  /// at all, so it is held for exactly as long as the list is open.
  Future<void> _openCastSheet() async {
    _castStatsSubscription = _engine?.stats.listen((stats) {
      _lastStats = stats;
    });
    await _showSheet(
      (context) => ValueListenableBuilder<List<CastDevice>>(
        valueListenable: _castDeviceList,
        builder: (context, devices, _) => CastDeviceSheet(
          devices: devices,
          connected: _castingTo,
          onSelect: (device) {
            Navigator.of(context).pop();
            unawaited(_startCast(device));
          },
          onDisconnect: () {
            Navigator.of(context).pop();
            unawaited(_stopCast());
          },
        ),
      ),
    );
    await _castStatsSubscription?.cancel();
    _castStatsSubscription = null;
  }

  /// What the stream says about itself, for the compatibility check: the
  /// stream the engine resolved when there is one, else the one this screen
  /// was opened with.
  StreamFacts get _streamFacts =>
      StreamFacts.of(_state?.selectedStream ?? StreamInfo(widget.stream));

  /// **What a receiver is sent and what the cast is judged by.** A stream
  /// played by id is cast by id ([_castUrl] publishes it), so this is the
  /// `xtremio://<id>` the engine reads; a stream read over HTTP is the URL
  /// as the core published it ([_opened]).
  Uri? get _castSource => _playingMediaId != null ? _engineUrl : _opened;

  /// The name the compatibility check reads: **the film, not the container
  /// it came in.** For an id the server found to be an archive or a disc
  /// image, the member's own name ([MediaResolution.memberName]); judging
  /// the container would refuse a `.rar` whose one member is an MP4 the
  /// receiver plays fine. Otherwise [castFilename], and failing that the
  /// name the server resolved the stream to (a torrent file's, a link's
  /// last segment). A name with no extension yields no container, and the
  /// check refuses an unknown one, which is a real answer, not a "not
  /// yet".
  String? get _castFilename {
    final resolution = _mediaResolution;
    final member = resolution?.memberName;
    if (member != null) return member.split('/').last;
    return castFilename(_state, serverFilename: _serverFilename) ??
        resolution?.name;
  }

  /// Hands the stream to [device], or explains why it cannot be.
  ///
  /// Nothing is loaded until every step has answered: the stream is one a
  /// receiver could play, the session starts, and a URL the receiver can
  /// fetch exists. A failure at any point leaves no session, no LAN listener
  /// and no remains of the session this one replaced, and says what
  /// happened.
  ///
  /// **Leaving the player is one of those endings.** Each step is a round
  /// trip the viewer can press Back inside, so every continuation asks
  /// [_stillOurs], and one that says no unwinds what this call started
  /// ([_teardownCast]): a session and a socket must not outlive the screen,
  /// and until the last line nothing else knows they exist.
  Future<void> _startCast(CastDevice device) async {
    final cast = _cast;
    // The id the engine reads, or the URL; see [_castSource]. Every step
    // below -- the check, the publication, the load -- is about this.
    final local = _castSource;
    if (cast == null || local == null || !_stillOurs) return;
    final state = _state;
    final compatibility = CastCompatibility.of(
      url: local,
      // Still the stream's own facts, and right for a member too: a
      // container is named after the release it holds, so the tags that
      // say HEVC or DTS are claims about the film inside it. They are
      // claims either way, believed only when they say something is
      // wrong.
      facts: _streamFacts,
      filename: _castFilename,
      stats: _lastStats,
      // A torrent the server has not named the file of yet: "not until it
      // has", answered without reopening anything, since the poll that names
      // it rebuilds this screen. A member is judged the same way:
      // [_reopenAt] restores the request ([_restoreTorrentStats]) that
      // [_failPlayback] cleared, so a member of a torrent is pending until a
      // poll names the file.
      containerPending: _torrentStatsRequest != null && _serverFilename == null,
      // A rendition needs the film's length for its playlist, and a device
      // that can make one; asked now, since a player registering libmpv is
      // what makes it so.
      canRepackage:
          _duration > Duration.zero &&
          (_mediaIds?.renditionsAvailable ?? false),
    );
    if (compatibility is CastRefused) {
      await _explainCast(compatibility.explanation, title: compatibility.title);
      return;
    }
    // Whatever session is running is about to be replaced, so its wait ends
    // here: starting a cast zeroes the listener's count, and a timer left
    // armed for the last receiver would read the new session's zero during
    // the load and end it. The next wait is armed after the load
    // ([_watchCastFetch]).
    _cancelCastFetch();
    // A session the switch itself ends is not one that ended elsewhere, and
    // the platform reports it the same way: see [_onCastSession]. Counted
    // down before any dialog, since a dialog can stay up for as long as the
    // viewer leaves it, and a session that really does end meanwhile is one
    // the screen has to hear about.
    _castStarts++;
    String? refusal;
    try {
      refusal = await _handToReceiver(
        cast,
        device,
        local,
        state,
        compatibility,
      );
    } finally {
      _castStarts--;
    }
    if (refusal != null) await _explainCast(refusal);
  }

  /// [_startCast] from the session on: the steps a switch of receivers
  /// runs through, answering why the cast did not happen when it did not.
  /// [compatibility] is [CastReady] or [CastRendition]: the stream as it
  /// is, or the server's repackaging of it.
  Future<String?> _handToReceiver(
    CastClient cast,
    CastDevice device,
    Uri local,
    PlayerState? state,
    CastCompatibility compatibility,
  ) async {
    final rendition = compatibility is CastRendition;
    // Stop stays on the bar while a second receiver is being picked, and
    // pressing it ends the cast, so every step below that finds a Stop has
    // happened unwinds like a leave. The unwinding also settles the
    // listener: a Stop during the enable sends its disable while the enable
    // is in flight, and `_lanMediaOn` is written from the enable's answer,
    // so the disable that counts is the one sent after that answer.
    final stops = _castStops;
    bool abandoned() => !_stillOurs || _castStops != stops;
    // What comes back, not the row that was tapped: the platform is asked
    // where the receiver is as a session starts and never during discovery,
    // so the answer is the only one of the two that can carry an address.
    final receiver = await cast.connect(device);
    if (receiver == null) {
      return 'Could not start a session with ${device.name}.';
    }
    // Starting a session is a round trip to the platform and then to the
    // receiver, and the viewer can leave the player during it. Every step
    // below acts -- on the engine, on the LAN listener, on the receiver --
    // so a leave stops here, and takes the session this call has just
    // started with it: it is the one thing that must not outlive the
    // screen, and nothing else knows about it yet.
    if (abandoned()) {
      await _teardownCast();
      return null;
    }
    final Uri? url;
    // A rendition is made for one start, the one it is published with: the
    // preparation below asks the server for what a receiver told to start
    // there asks first, and the receiver is told exactly that. So local
    // playback stops here, at that position, rather than drift past it
    // while the preparation runs.
    final resumeAfter = rendition && _playing;
    if (rendition) await _engine?.pause();
    try {
      url = await _castUrl(local, receiver, rendition: rendition);
    } catch (error) {
      // The server would not publish the stream: an id it let go, a
      // listener that stopped under the switch. The kind, never a token.
      DiagnosticsLog.warn(
        'player',
        'the stream could not be published for a receiver: '
            '${error is MediaRefusal ? error.kind : error.runtimeType}',
      );
      await _endLanMedia();
      await cast.disconnect();
      await _stopCast(disconnect: false);
      return 'This device could not hand the stream to ${device.name}.';
    }
    if (url == null) {
      DiagnosticsLog.warn(
        'player',
        'no address to give a receiver at '
            '${receiver.address ?? 'an address it did not report'}',
      );
      await _endLanMedia();
      await cast.disconnect();
      // That disconnect ended whatever session was running, which on a
      // switch away from a live one is the session this screen is still
      // showing: end it here rather than wait for the client's report of it.
      // A no-op when nothing was casting.
      await _stopCast(disconnect: false);
      return '${device.name} cannot reach this device over the network, so '
          'there is no address to give it. Casting a loopback URL it could '
          'never fetch would only look like it worked.';
    }
    // The LAN listener is up by now, so this takes that with it too.
    if (abandoned()) {
      await _teardownCast();
      return null;
    }
    // A rendition is made ready before the receiver hears of it: its first
    // answer waits for the film's index and its first slots, and a receiver
    // left on a silent load gives up.
    if (rendition) {
      final ready = await _prepareRendition(device, abandoned);
      if (abandoned()) {
        await _teardownCast();
        // A Cancel leaves the film here, playing as it was; a leave does
        // not touch the engine at all.
        if (_stillOurs && resumeAfter) await _engine?.play();
        return null;
      }
      if (ready != null) {
        DiagnosticsLog.warn(
          'player',
          'a rendition could not be prepared for a receiver: ${ready.phase}',
        );
        await _teardownCast();
        if (_stillOurs && resumeAfter) await _engine?.play();
        return ready.sentence ??
            'This device could not hand the stream to ${device.name}.';
      }
    }
    // The start the receiver is told: a rendition's is the one it was
    // published and prepared for.
    final position = rendition
        ? (_castRenditionStart ?? _position.value)
        : _position.value;
    // Local playback stops here, before the receiver starts: two copies of
    // the same film, a few seconds apart, is nobody's idea of casting.
    await _engine?.pause();
    // Pausing is a round trip too, and the `setState` below puts the screen
    // into casting, where [build] draws no video. On a leaving screen that
    // would take the picture out for the rest of the teardown wait, whose
    // point is that the sinks stay drained ([_leave]).
    if (abandoned()) {
      await _teardownCast();
      return null;
    }
    setState(() {
      _castingTo = device;
      _castNote = null;
      _castEnded = false;
      _castHandedAt = position;
      _castReported = false;
      _castStatus = CastStatus(
        state: CastPlayerState.buffering,
        position: position,
        duration: _duration > Duration.zero ? _duration : null,
      );
    });
    // What we handed the receiver, and which address it was picked for. Not
    // the receiver's name, which is as often a person's as a room's, and
    // never a published token's URL, which is a way into this device.
    DiagnosticsLog.info(
      'player',
      'casting ${_castToken != null ? 'a published stream from ${url.host}:${url.port}' : DiagnosticsLog.url(url)} '
          'to a receiver at '
          '${receiver.address ?? 'an address it did not report'}',
    );
    try {
      await cast.load(
        CastMedia(
          url: url,
          contentType: switch (compatibility) {
            CastReady(:final contentType) => contentType,
            _ => CastRendition.contentType,
          },
          title: state?.title ?? '',
          duration: rendition ? _duration : null,
        ),
        start: position,
      );
    } catch (error) {
      // A receiver turning the media down does not come back this way (the
      // plugin answers at once and the refusal arrives later as a media
      // status, which the wait below is for). This is the platform itself
      // refusing: a session gone between connect and load, a native
      // exception. Nobody awaits this call, so it is undone here the way the
      // no-address branch undoes it, and the viewer hears why.
      DiagnosticsLog.warn(
        'player',
        'the receiver did not take the media: $error',
      );
      if (abandoned()) {
        await _teardownCast();
        return null;
      }
      await _stopCast();
      return '${device.name} did not accept the stream.';
    }
    // A receiver accepting the media is another round trip. Left during
    // it, the wait below would be a timer armed after [_detach] ran, and
    // the receiver would be left playing a stream off a device whose
    // listener is about to go.
    if (abandoned()) {
      await _teardownCast();
      return null;
    }
    _watchCastFetch();
    return null;
  }

  /// **Makes the published rendition's start before the receiver is told
  /// to load it**, and answers null once it is ready -- or what refused it
  /// (a `failed` readiness with its sentence, or `ended`). A Cancel, a Stop
  /// or leaving the screen ends the wait; the caller asks [abandoned].
  ///
  /// The receiver (the Chromecast default receiver, Chrome 92) gives up on
  /// a load whose first answer stays silent too long, and a rendition's
  /// first answer waits for the film's index -- a Matroska file's is at its
  /// end -- and the slot it starts in: a minute behind a thin swarm,
  /// measured. So the server is asked to make them first
  /// ([MediaIds.prepareRendition]) and asked how far it has got every
  /// [PlayerScreen.castPreparePoll], with the phase on the card over the
  /// video. **Local playback is paused meanwhile, at the start the
  /// rendition is published with**: the server makes what a receiver told
  /// to start there asks first (the header, slot 0, the slot for the
  /// start), and the receiver is told exactly that start -- a phone that
  /// played on would hand over a position nothing was made for. A Cancel or
  /// a refusal resumes it. No give-up timer: a stalled source is waited
  /// for, and the viewer is the one who cancels.
  Future<RenditionReadiness?> _prepareRendition(
    CastDevice device,
    bool Function() abandoned,
  ) async {
    final ids = _mediaIds;
    final token = _castToken;
    if (ids == null || token == null) return null;
    setState(() {
      _castPreparingFor = device;
      _castPreparingPhase = 'index';
    });
    try {
      await ids.prepareRendition(token);
      while (!abandoned()) {
        final readiness = await ids.renditionReadiness(token);
        if (abandoned()) return null;
        if (readiness.phase == 'ready') return null;
        if (!readiness.preparing) return readiness;
        if (readiness.phase != _castPreparingPhase && mounted) {
          setState(() => _castPreparingPhase = readiness.phase);
        }
        final wake = Completer<void>();
        _castPrepareWake = wake;
        _castPrepareTimer = Timer(PlayerScreen.castPreparePoll, () {
          if (!wake.isCompleted) wake.complete();
        });
        await wake.future;
      }
      return null;
    } finally {
      _castPrepareTimer?.cancel();
      _castPrepareTimer = null;
      _castPrepareWake = null;
      if (mounted) setState(() => _castPreparingFor = null);
    }
  }

  /// Ends a preparation's wait now: Cancel, Stop, leaving the screen.
  void _wakeCastPrepare() {
    _castPrepareTimer?.cancel();
    _castPrepareTimer = null;
    final wake = _castPrepareWake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// The card's Cancel: the rendition is unpublished, the session ended,
  /// and the film never left this screen.
  void _cancelCastPrepare() {
    _castStops++;
    _wakeCastPrepare();
  }

  /// Starts the wait that asks whether the receiver ever came back for the
  /// stream ([_castFetchCheck]).
  ///
  /// Only for a stream served off this device: a receiver fetching from a
  /// host on the internet owes our listener nothing, and its count would
  /// stay at zero however well the cast was going.
  void _watchCastFetch() {
    _cancelCastFetch();
    if (!_lanMediaOn) return;
    _castFetchTimer = Timer(
      PlayerScreen.castFetchTimeout,
      () => unawaited(_castFetchCheck()),
    );
  }

  /// Ends the wait. What it asks is about a session, so every way out of
  /// one comes through here -- Stop, a session that ended elsewhere, a
  /// failed start, another receiver picked in its place, [dispose] -- and
  /// so does arming the next one.
  void _cancelCastFetch() {
    _castFetchTimer?.cancel();
    _castFetchTimer = null;
  }

  /// **Three readings of the listener's two counts** (stream-server
  /// `docs/lan-media.md`):
  ///
  /// - **Nothing reached this device.** The address is one the receiver
  ///   cannot route to, and a hanging connect never fails on its own, so
  ///   the session ends as Stop ends it and the film comes back here, with
  ///   the reason said.
  /// - **It reached this device and has been sent nothing yet** -- requests,
  ///   no body. A refusal (which the server logged), or a stream whose
  ///   bytes are not here yet. Said on the remote ([_castNote]), and asked
  ///   again after as long: **never an ending.** A stream that is slow to
  ///   come is waited for; the viewer is the one who gives up.
  /// - **A body began.** The network and the server did their part, and
  ///   the rest is the media's: the viewer hears nothing, since a receiver
  ///   that is buffering and one that cannot decode look alike from here.
  Future<void> _castFetchCheck() async {
    _castFetchTimer = null;
    if (!mounted || !_casting) return;
    final requests = _lanMedia?.lanMediaRequestsServed ?? 0;
    if (requests == 0) {
      final device = _castingTo;
      DiagnosticsLog.warn(
        'player',
        'receiver asked the LAN listener for nothing; ending the session',
      );
      await _stopCast();
      await _explainCast(
        '${device?.name ?? 'The receiver'} never asked for the stream, so it '
        'could not reach this device at the address it was given. The film '
        'is back on this screen.',
      );
      return;
    }
    final bodies = _lanMedia?.lanMediaBodiesServed ?? 0;
    if (bodies > 0) {
      DiagnosticsLog.info(
        'player',
        'receiver asked the LAN listener for $requests request(s) and was '
            'sent $bodies bod${bodies == 1 ? 'y' : 'ies'}',
      );
      if (_castNote != null) setState(() => _castNote = null);
      return;
    }
    if (_castNote == null) {
      DiagnosticsLog.warn(
        'player',
        'receiver asked the LAN listener for $requests request(s) and has '
            'been sent nothing yet',
      );
      setState(
        () => _castNote =
            '${_castingTo?.name ?? 'The receiver'} has reached this device '
            'and has not been sent any of the film yet.',
      );
    }
    _castFetchTimer = Timer(
      PlayerScreen.castFetchTimeout,
      () => unawaited(_castFetchCheck()),
    );
  }

  /// The URL to give [device] for the stream this player has open, or null
  /// when there is none it could fetch.
  ///
  /// **A stream played by id is published** ([MediaIds.publish]): the LAN
  /// media listener goes up, and the receiver is handed
  /// `<lan base>/cast/<token>` -- one random token for this one stream,
  /// served with the play this screen's player had, so a torrent shares as
  /// it does on this device. The listener serves published tokens and
  /// nothing else, so every kind casts the same way: a torrent, a link
  /// through the server's cache, a Drive file, a download, a file on this
  /// device, the film inside an archive. Throws when the server will not
  /// publish it.
  ///
  /// **A [rendition] is published as one** ([MediaIds.publishRendition]):
  /// the same listener and token rules, and the receiver is handed the
  /// token's file, `<lan base>/cast/<token>/stream.mp4`: one fragmented MP4
  /// the server makes as it is read, its first part from this player's
  /// position, with the audio track it is playing. It has a length and
  /// ranges and an index of its segments, so the receiver seeks in it by
  /// bytes like any file -- its remote's seeks and this screen's `SEEK`s
  /// alike (stream-server `docs/design/renditions.md` §2.8).
  ///
  /// A stream read over HTTP -- an origin that will not serve ranges -- is
  /// handed over as it is when it is on another internet host, and has no
  /// address a receiver could use when it is on this device.
  Future<Uri?> _castUrl(
    Uri local,
    CastDevice device, {
    bool rendition = false,
  }) async {
    final id = mediaIdOf(local);
    if (id == null) return isEmbeddedServerHost(local.host) ? null : local;
    final ids = _mediaIds;
    final lan = _lanMedia;
    if (_serverBase == null || ids == null || lan == null) return null;
    try {
      await lan.setLanMedia(enabled: true);
    } catch (error) {
      DiagnosticsLog.warn('player', 'LAN media listener refused: $error');
      return null;
    }
    _lanMediaOn = true;
    final base = await lan.lanMediaBaseUrl(peerIp: device.address);
    if (base == null) return null;
    // A switch of receivers: the last one's token goes before this one's
    // is handed out, so one stream is published once.
    await _unpublishCast();
    if (rendition) {
      final start = _position.value;
      _castRenditionStart = start;
      final token = await ids.publishRendition(
        id,
        RenditionSpec(
          duration: _duration,
          start: start,
          audioTrack: _castAudioTrack,
        ),
      );
      _castToken = token;
      return base.resolve('cast/$token/stream.mp4');
    }
    final token = await ids.publish(id);
    _castToken = token;
    return base.resolve('cast/$token');
  }

  /// The audio track playing here, by its place among the film's audio
  /// tracks -- mpv lists them in the file's order, which is how the server
  /// counts them. The first when none is said to be selected.
  int get _castAudioTrack {
    final tracks = _tracks.value;
    final at = tracks.audio.indexWhere(
      (track) => track.id == tracks.activeAudioId,
    );
    return at < 0 ? 0 : at;
  }

  /// Withdraws the publication the receiver was handed, if there is one:
  /// nothing more is served under its token, and a body in flight is cut.
  /// Every way out of a session comes through here ([_endLanMedia]), and so
  /// does a switch of receivers and a new stream on this screen.
  Future<void> _unpublishCast() async {
    final token = _castToken;
    _castToken = null;
    if (token == null) return;
    try {
      await _mediaIds?.unpublish(token);
    } catch (error) {
      DiagnosticsLog.warn(
        'player',
        'could not withdraw the published stream: ${error.runtimeType}',
      );
    }
  }

  /// Ends the session and brings playback back to this device, at the point
  /// the receiver had reached.
  ///
  /// [disconnect] false when the session is already gone (it ended
  /// elsewhere) and there is nothing left to end.
  Future<void> _stopCast({bool disconnect = true}) async {
    if (!_casting) return;
    _castStops++;
    _cancelCastFetch();
    final position = _castStatus.position;
    _castingTo = null;
    _castNote = null;
    if (mounted) setState(() {});
    if (disconnect) await _cast?.disconnect();
    await _endLanMedia();
    // Ending the session is a round trip, and what follows it puts the
    // film back on this device's engine -- which is the one thing a
    // player being released must not be asked to do.
    if (!_stillOurs) return;
    _position.value = position;
    _playingNormally = false;
    _playedSinceSeek = Duration.zero;
    // Through the hold: a cast started before the local file was in hands
    // the film back to an engine that will drop a plain seek.
    _seekEngineTo(position);
    await _engine?.play();
  }

  /// Withdraws the publication and closes the LAN media listener, if this
  /// screen is what opened it. The listener exists for the length of a
  /// session and no longer, so every
  /// way out of one comes through here: Stop, a session that ended
  /// elsewhere, a failed start, and [dispose].
  Future<void> _endLanMedia() async {
    _cancelCastFetch();
    await _unpublishCast();
    if (!_lanMediaOn) return;
    _lanMediaOn = false;
    try {
      await _lanMedia?.setLanMedia(enabled: false);
    } catch (error) {
      DiagnosticsLog.warn('player', 'could not stop the LAN listener: $error');
    }
  }

  /// Leaving the player while a receiver has the stream: the session goes
  /// and so does the listener. Leaving the receiver playing would mean
  /// leaving a socket open to the network for it, which is exactly what
  /// must not outlive a session.
  Future<void> _teardownCast() async {
    _castingTo = null;
    await _cast?.disconnect();
    await _endLanMedia();
  }

  /// Says why casting did not happen. A dialog, because it is the answer to
  /// something that was asked for and it is worth reading.
  Future<void> _explainCast(String explanation, {String? title}) async {
    if (!_stillOurs) return;
    await showDialog<void>(
      context: context,
      builder: (context) => CastRefusedDialog(
        explanation: explanation,
        title: title ?? CastRefusedDialog.defaultTitle,
      ),
    );
  }
}
