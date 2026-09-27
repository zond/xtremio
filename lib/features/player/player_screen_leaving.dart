part of 'player_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// Leaving the player: detaching, the teardown, and ending the proxied
/// streams.
extension _PlayerLeaving on _PlayerScreenState {
  /// Leaves the player past that ladder: the remote's Stop key and the
  /// bar's own back arrow both end the session, and what happens to be on
  /// screen at the time does not change that.
  ///
  /// The ladder belongs to Back, which is one key for every layer and so
  /// has to take them in order. The arrow is a control the viewer aimed
  /// at, and the layer it would put away first is the OSD it is drawn on.
  void _leavePlayer() => unawaited(_leave());

  /// Cuts this screen off from everything that could still act on the
  /// player, before anything about the leaving is awaited.
  ///
  /// The wait put this screen somewhere it had never been. It used to pop
  /// at the press and release the engine two frames later, so by the time
  /// mpv was being stopped there was no screen left to answer an event.
  /// Now it stays -- built, subscribed, and holding an engine that is
  /// being released -- for as long as the teardown takes, and every
  /// subscription and every timer it still owns is a way for the last
  /// seconds of a session to reach a player on its way out. An `open` on
  /// it (the false-end recovery), a `pause` (the app going to the
  /// background), a `seek` and a `play` (a cast session ending
  /// elsewhere), and -- the one that cost the viewer something -- a
  /// `TimeChanged` of zero, because media_kit's `stop` announces itself
  /// with `position: Duration.zero` while the duration is still the
  /// film's, and a film left half-watched came back offering itself from
  /// the beginning.
  ///
  /// **So it is one act rather than a guard per handler.** A guard has to
  /// be remembered by whoever writes the next handler, and there is
  /// nothing about a handler that says it needs one; a screen with no
  /// subscriptions and no timers cannot be reached by anything, including
  /// what has not been written yet. What is left running afterwards is the
  /// build -- the picture, which is the whole reason the screen is still
  /// here.
  ///
  /// **What it cannot cancel is a continuation.** An `await` that was
  /// already in flight when the press landed is neither a subscription nor
  /// a timer; there is nothing here to cancel it with, and it resumes into
  /// the middle of the wait. That half is [_stillOurs], which every such
  /// continuation asks -- and which says there why `mounted` on its own
  /// stopped being an answer the moment this wait existed.
  ///
  /// **[State.dispose] is no longer the place for this.** It used to be
  /// the moment the screen stopped existing and so the moment everything
  /// it owned stopped mattering; with the wait in front of it, it runs
  /// after the events it was cancelling have already been answered. It
  /// still calls this, because a screen can go without a leave (the
  /// hand-over's `pushReplacement`, a route dismantled from above), and
  /// this is idempotent so that a screen going through both paths detaches
  /// once.
  ///
  /// The core field listeners go too: `player` is what opens a stream, and
  /// `ctx` writes the subtitle style onto the engine. The preferences
  /// listener stays where it is, because what it answers is a `setState`
  /// and it reaches neither the engine nor the core.
  void _detach() {
    if (_detached) return;
    _detached = true;
    _lifecycle.dispose();
    _player?.removeListener(_onPlayerState);
    _ctx?.removeListener(_onCtx);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    unawaited(_castStatsSubscription?.cancel());
    _castStatsSubscription = null;
    unawaited(_stuckSample?.cancel());
    _stuckSample = null;
    _cancelCastFetch();
    _cancelOpenRetry();
    _stopTorrentStats();
    _stopStreamNumbers();
    _statsHoverTimer?.cancel();
    _statsHoverTimer = null;
    _seekCheck?.cancel();
    _seekCheck = null;
    _pauseUpNext();
    _controlsTimer?.cancel();
    _controlsTimer = null;
    _stuckTimer?.cancel();
    _stuckTimer = null;
    _subtitleFailureTimer?.cancel();
    _subtitleFailureTimer = null;
  }

  /// Stops the player, waits for it, and only then leaves the screen.
  ///
  /// The order is the whole of it, and it is the reverse of what this
  /// screen used to do. The `quit` goes out first, because it is the kill
  /// and because it is what makes the `stop` inside the teardown come back
  /// promptly instead of waiting out a five-minute `network-timeout`. Then
  /// the teardown is awaited *with the video still in the tree and the
  /// audio device still open* -- media_kit releases both from inside it,
  /// after the stop, so the sinks are alive and being drained for exactly
  /// as long as mpv might still be handing them something. Only then does
  /// the screen go.
  ///
  /// It used to be the other way round -- leave at once, release two
  /// frames later through a future nobody held, quit only on a deadline --
  /// which is what [PlayerScreen.teardownBound] and [PlaybackEngine.quit]
  /// are each written against from their own side.
  ///
  /// **The wait yields; it never blocks.** An `await` leaves Flutter free
  /// to go on producing frames, which is what keeps something draining the
  /// video sink. A blocking join here would deadlock in precisely the case
  /// worth waiting for -- mpv waiting on the sink, the sink waiting on us
  /// -- and that is not hypothetical: it is what the community Android
  /// client does, `pthread_join` and then `mpv_terminate_destroy` inline
  /// on the UI thread, and an ANR is what it gets for it.
  ///
  /// **Keeping the sinks alive means keeping them consuming**, not merely
  /// undestroyed, which is why the wait happens here rather than from
  /// [dispose]: a screen that has already gone has nothing drawing the
  /// texture. Measured on both platforms, mpv's video output does not in
  /// fact block when nothing consumes -- eight seconds with the `Video`
  /// widget out of the tree advanced playback normally on Linux and on the
  /// Chromecast -- so this is the ordering that is safe by construction
  /// rather than by measurement, and it costs nothing.
  ///
  /// The wait is bounded and the pop is not conditional on it: a player
  /// that will not stop keeps the viewer for [PlayerScreen.teardownBound]
  /// and no longer, and finishes -- or does not -- in the background,
  /// where the teardown itself says which.
  Future<void> _leave([PlayerScreenResult? result]) async {
    if (_leaving) return;
    setState(() => _leaving = true);
    // Nothing may act on the player from here on, and this is the line
    // that says so: it comes before the first `await` below, because what
    // it stops is precisely what would otherwise get a turn during one.
    _detach();
    // The control bar leaves the frame with this ([build]), so nothing may
    // be left focused on it: hiding the bar and handing the remote back to
    // the video are one act, and a leave is no exception. The timer that
    // would have done it has gone with [_detach].
    if (_controlFocused) _focusNode.requestFocus();
    // From the press, not from the pop: the display is not presenting a
    // film any more the moment the viewer says so.
    _releaseDisplayFrameRate();
    final navigator = Navigator.of(context);
    // Nothing is logged here when the bound expires. The teardown times
    // itself, because it outlives this wait and because a hand-over runs
    // it with no screen waiting on it at all.
    await _endPlayback().timeout(PlayerScreen.teardownBound, onTimeout: () {});
    // Gone under us while we waited -- a hand-over, or the route
    // dismantled from above. There is no screen of ours left to leave.
    if (!mounted) return;
    if (navigator.canPop()) navigator.pop(result);
  }

  /// Ends the server's reads for this player, and retires the name they
  /// were opened under.
  ///
  /// The engine's release is about to be waited on and can block for as
  /// long as mpv is blocked, and what mpv is most often blocked *on* is a
  /// read from a stream that has stopped arriving. `network-timeout` is
  /// five minutes on purpose -- a thin swarm legitimately takes minutes to
  /// hand over the next piece, and a shorter bound would end healthy
  /// playbacks -- so waiting for it is waiting for a player nobody wants
  /// any more. This makes the read fail now instead.
  ///
  /// **Breaking the read is only half of it, and on its own it is not even
  /// the useful half.** ffmpeg runs with `reconnect=1`, so a body that
  /// stops mid-file is re-fetched through the URL it already has, token and
  /// all: measured against real libmpv, three closes on one live reader
  /// produced three fresh fetches from the origin. What ends the stream is
  /// that the server *retires the token* at the same time and answers `410
  /// Gone` to anything that arrives bearing it afterwards. The order the
  /// server documents is quit-then-close, because a demuxer that has
  /// already been cancelled never reaches its reconnect at all -- and that
  /// is now the order this runs in, since [_endPlayback] sends the quit
  /// before it gets here. The refusal is what covers the case where mpv
  /// had not reached the quit yet: a reconnect provoked on the way out
  /// meets a `410` rather than a fresh body.
  ///
  /// **It is a socket and nothing more.** A demuxer wedged somewhere other
  /// than a read -- handing a frame to the Flutter texture, waiting on the
  /// audio device -- is not polling this stream and is untouched by
  /// closing it. What covers that player is the quit ahead of this and the
  /// bound behind it. And a player that has stopped reading altogether
  /// observes the close when it next reads, or never.
  ///
  /// Synchronous and unawaited: it is a map scan on the Rust side, and a
  /// teardown has nothing to do with its answer. The answer is written
  /// down when it is not zero, and that line is the point -- the evening
  /// this whole path was built for produced a player that outlived its
  /// screen by ninety seconds and a log that said nothing at all about it,
  /// so "this player left and took its stream with it" is exactly the
  /// sentence a report was missing. Zero is ordinary (the stream may have
  /// finished on its own, or the server may be gone) and is worth no
  /// line.
  ///
  /// **Nothing it does may escape.** It reaches FFI, and FFI throws -- if
  /// the core panicked, if the bridge is not up. A throw crossing this
  /// would take the release that follows it down as well, leaving a player
  /// holding everything the close was added to free. A close that failed
  /// is a report worth a line and nothing more: the server times the
  /// stream out eventually, and the player is being released either way.
  void _closeProxiedStreams() {
    if (!_proxiedStream) return;
    final int closed;
    try {
      closed = _proxyStreams?.closeProxyStreams(_proxyToken) ?? 0;
    } catch (error) {
      DiagnosticsLog.error(
        'player',
        'could not end the proxied streams for the player being left: $error',
      );
      return;
    }
    if (closed > 0) {
      DiagnosticsLog.info(
        'player',
        'ended $closed proxied stream${closed == 1 ? '' : 's'} for the '
            'player being left',
      );
    }
  }

  /// Ends this player: the `quit`, then the streams it was reading, then
  /// the release -- and answers for how long the whole of it took.
  ///
  /// Run once per screen and shared: [_leave] awaits what this returns
  /// with the video still on screen, and [dispose] falls back to it
  /// unwatched for the screens that never had a leave. Both can happen to
  /// one screen -- a leave that gave up at the bound is disposed while its
  /// teardown is still out -- so the future is kept rather than the work
  /// repeated. Sending a second `quit` would be harmless (the engine
  /// refuses it) and disposing a released media_kit `Player` twice is an
  /// `AssertionError`.
  ///
  /// **The quit is dispatched before anything is awaited.** It is the
  /// first statement, it is an enqueue on mpv's dispatch queue and nothing
  /// else, and it is what everything after it depends on being fast.
  ///
  /// Neither half may throw out of here. The quit throws when libmpv
  /// refused the command outright, which means the player is still
  /// running and is worth a line. The release throws when mpv refused to
  /// stop, which is worth a line and must not skip the rest -- the streams
  /// are closed before it for exactly that reason, and there is nothing
  /// after it to skip.
  Future<void> _endPlayback() => _teardown ??= _runTeardown();

  /// The body of [_endPlayback], separate only so that the memo above it
  /// stays a single line.
  Future<void> _runTeardown() async {
    final engine = _engine;
    final started = DateTime.now();
    // The instrument, and the only one there is. Nothing is escalated to
    // when it fires -- the quit two lines below is the kill, and it will
    // have gone out long since -- so all it does is write down that a
    // player which should have stopped in a fraction of a second has not.
    // Armed here rather than by the waiting screen because it has to cover
    // the hand-over too, where no screen is waiting to notice.
    var overdue = false;
    final bound = Timer(PlayerScreen.teardownBound, () {
      overdue = true;
      DiagnosticsLog.warn(
        'player',
        'the player has not stopped ${PlayerScreen.teardownBound.inSeconds}s '
            'after it was left; it is still holding its memory and its socket',
      );
    });
    try {
      try {
        await engine?.quit();
      } catch (error) {
        DiagnosticsLog.error(
          'player',
          'the player refused the quit on the way out: $error',
        );
      }
      _closeProxiedStreams();
      try {
        await engine?.dispose();
      } catch (error) {
        DiagnosticsLog.error('player', 'releasing the player failed: $error');
      }
    } finally {
      bound.cancel();
      // Only a teardown that came back at all can say it was late, which
      // is the distinction a report is read for: "slow" and "never
      // stopped" want different things looked at next.
      if (overdue) {
        final took = DateTime.now().difference(started);
        DiagnosticsLog.info(
          'player',
          'the player stopped ${took.inSeconds}s after it was left',
        );
      }
    }
  }
}
