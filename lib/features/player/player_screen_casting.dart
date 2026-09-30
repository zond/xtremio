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

  /// **What a receiver is sent and what the cast is judged by: the film, not
  /// the container it came in.** For an archive or disc image this is the
  /// member URL the server serves ([_translatedUrl]), which mpv is playing;
  /// judging the container would refuse a `.rar` whose one member is an MP4
  /// the receiver plays fine. Otherwise it is [_opened].
  Uri? get _castSource => _translatedUrl ?? _opened;

  /// The name the compatibility check reads, which has to be the name of
  /// whatever [_castSource] is.
  ///
  /// For a member, the last segment of the URL the archive route redirected
  /// to, which ends in the film's own file name (see `routeArchive`).
  /// [castFilename] would name the container there (`streamName` and the
  /// addon's `behaviorHints.filename` are the `.rar`), so it is not
  /// consulted at all once there is a member. A member name with no
  /// extension yields null and the check refuses an unknown container, which
  /// is a real answer, not a "not yet".
  String? get _castFilename {
    final member = _translatedUrl;
    if (member == null) {
      return castFilename(_state, serverFilename: _serverFilename);
    }
    final segments = member.pathSegments;
    return segments.isEmpty ? null : segments.last;
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
    // The film, which for a container is the member inside it; see
    // [_castSource]. Every step below -- the check, the LAN address, the
    // load -- is about this URL and no longer about the archive around it.
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
        compatibility as CastReady,
      );
    } finally {
      _castStarts--;
    }
    if (refusal != null) await _explainCast(refusal);
  }

  /// [_startCast] from the session on: the steps a switch of receivers
  /// runs through, answering why the cast did not happen when it did not.
  Future<String?> _handToReceiver(
    CastClient cast,
    CastDevice device,
    Uri local,
    PlayerState? state,
    CastReady compatibility,
  ) async {
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
    final url = await _castUrl(local, receiver);
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
    final position = _position.value;
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
    // the receiver's name, which is as often a person's as a room's.
    DiagnosticsLog.info(
      'player',
      'casting ${DiagnosticsLog.url(url)} to a receiver at '
          '${receiver.address ?? 'an address it did not report'}',
    );
    try {
      await cast.load(
        CastMedia(
          url: url,
          contentType: compatibility.contentType,
          title: state?.title ?? '',
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

  /// Starts the wait that asks, once, whether the receiver ever came back
  /// for the stream ([_castFetchCheck]).
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

  /// Whether the receiver ever reached this device, which is all the
  /// listener's count says.
  ///
  /// Nothing reached it: the address is one it cannot route to, and a
  /// hanging connect never fails on its own, so the session ends as Stop
  /// ends it and the film comes back here, with the reason said. Something
  /// did: the viewer hears nothing, since twenty seconds cannot tell slow
  /// buffering from a decode failure; the log gets it.
  Future<void> _castFetchCheck() async {
    _castFetchTimer = null;
    if (!mounted || !_casting) return;
    final served = _lanMedia?.lanMediaRequestsServed ?? 0;
    if (served > 0) {
      DiagnosticsLog.info(
        'player',
        'receiver has asked the LAN listener for $served request(s)',
      );
      return;
    }
    final device = _castingTo;
    DiagnosticsLog.warn(
      'player',
      'receiver asked the LAN listener for nothing; ending the session',
    );
    await _stopCast();
    await _explainCast(
      '${device?.name ?? 'The receiver'} never asked for the stream, so it '
      'could not reach this device at the address it was given. The film is '
      'back on this screen.',
    );
  }

  /// The URL to give [device] for the stream this player has open, or null
  /// when there is none it could fetch.
  ///
  /// A stream on another internet host is handed over as it is. Only a URL
  /// on the embedded server needs the LAN media listener, which is the only
  /// case that starts one. For a container [local] is the member's URL on
  /// the archive stream routes, which the listener serves
  /// (`lan_media_routes()` mounts `archive_stream_routes()`); it does not
  /// mount the archive `/create` half, which fetches a caller-named URL, so
  /// the member is rebuilt on the LAN base rather than re-created there, and
  /// the receiver's reads keep its session leased.
  Future<Uri?> _castUrl(Uri local, CastDevice device) async {
    if (!isEmbeddedServerHost(local.host)) return local;
    // Every loopback URL is the embedded server's ([isEmbeddedServerHost]),
    // and the LAN listener serves its routes, so any of them is rebuilt on
    // the listener -- unless this build started no server of its own, when
    // nothing here serves it at all.
    if (_serverBase == null) return null;
    final lan = _lanMedia;
    if (lan == null) return null;
    try {
      await lan.setLanMedia(enabled: true);
    } catch (error) {
      DiagnosticsLog.warn('player', 'LAN media listener refused: $error');
      return null;
    }
    _lanMediaOn = true;
    final base = await lan.lanMediaBaseUrl(peerIp: device.address);
    if (base == null) return null;
    final onLan = local.replace(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
    );
    // A torrent cast is this screen's playback moved to the receiver, so it
    // carries the same player token ([withPlayerToken]): the server keeps
    // the same play session, and shares from it exactly as it does while
    // the film plays here. An archive member does not ([_bufferOnUrlFor]):
    // archive playback shares nothing, cast or not.
    return _bufferOnUrlFor(local) ? withPlayerToken(onLan, _proxyToken) : onLan;
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
    await _engine?.seek(position);
    await _engine?.play();
  }

  /// Closes the LAN media listener, if this screen is what opened it. The
  /// listener exists for the length of a session and no longer, so every
  /// way out of one comes through here: Stop, a session that ended
  /// elsewhere, a failed start, and [dispose].
  Future<void> _endLanMedia() async {
    _cancelCastFetch();
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
