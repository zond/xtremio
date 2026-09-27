part of 'player_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// Leaving the player: detaching, the teardown, and ending the proxied
/// streams.
extension _PlayerLeaving on _PlayerScreenState {
  /// Leaves the player past the Back ladder: the remote's Stop key and the
  /// bar's own back arrow end the session whatever is on screen. The arrow is
  /// a control the viewer aimed at; only Back, one key for every layer, comes
  /// down the ladder.
  void _leavePlayer() => unawaited(_leave());

  /// Cuts this screen off from everything that could still act on the
  /// player, before anything about the leaving is awaited.
  ///
  /// The screen stays up, holding an engine that is being released, for as
  /// long as the teardown takes, and every subscription and timer it still
  /// owns is a way for the session's last seconds to reach that player: an
  /// `open` (the false-end recovery), a `pause` (the app going to the
  /// background), a `seek` and `play` (a cast ending elsewhere), and a
  /// `TimeChanged` of zero from media_kit's `stop`, which would reset
  /// continue-watching. **So it is one act rather than a guard per
  /// handler**: a screen with no subscriptions and no timers cannot be
  /// reached by anything, including handlers not written yet.
  ///
  /// An `await` already in flight is not cancelled here; that half is
  /// [_stillOurs].
  ///
  /// [dispose] calls this too, for a screen that goes without a leave (the
  /// hand-over's `pushReplacement`, a route dismantled from above); it runs
  /// once. The core field listeners go (`player` opens a stream, `ctx` writes
  /// the subtitle style); the preferences listener stays, since it only
  /// calls `setState`.
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
  /// The order is the rule (docs/ARCHITECTURE.md, "Leaving the player"):
  /// [_detach], then the `quit` -- the kill, which also makes the `stop`
  /// inside the teardown return promptly instead of waiting out a five-minute
  /// `network-timeout` -- then the teardown, awaited *with the video still in
  /// the tree and the audio device open*, since media_kit releases both from
  /// inside it, after the stop. Only then does the screen go.
  ///
  /// **The wait yields; it never blocks.** An `await` leaves Flutter
  /// producing frames, which keeps the video sink drained; a blocking join
  /// here could deadlock with mpv waiting on the sink. It happens here
  /// rather than in [dispose] because a screen that has gone draws nothing.
  ///
  /// The wait is bounded by [PlayerScreen.teardownBound] and the pop does not
  /// depend on it: a player that will not stop finishes, or does not, in the
  /// background, and the teardown logs which.
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

  /// Ends the server's reads for this player, and retires the name they were
  /// opened under.
  ///
  /// The engine's release can block for as long as mpv is blocked, most
  /// often on a read from a stream that stopped arriving, and
  /// `network-timeout` is five minutes on purpose (a thin swarm legitimately
  /// takes minutes). This makes that read fail now.
  ///
  /// **Breaking the read is not enough on its own:** ffmpeg runs with
  /// `reconnect=1` and re-fetches through the URL it has (measured: three
  /// closes on one live reader produced three fresh fetches). What ends the
  /// stream is the server *retiring the token* at the same time and
  /// answering `410 Gone` to anything that arrives with it. The server's
  /// order is quit-then-close, which [_endPlayback] keeps.
  ///
  /// It frees a socket and nothing more: a demuxer wedged elsewhere (handing
  /// a frame to the texture, waiting on the audio device) is covered by the
  /// quit ahead of this and the bound behind it.
  ///
  /// Synchronous and unawaited (a map scan on the Rust side). A non-zero
  /// count is logged, since "this player left and took its stream with it"
  /// is the line a report needs. **Nothing it does may escape**: FFI can
  /// throw, and a throw here would skip the release that follows.
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

  /// Ends this player: the `quit`, then the streams it was reading, then the
  /// release -- and logs how long the whole of it took.
  ///
  /// Run once per screen and shared: [_leave] awaits it with the video on
  /// screen, and [dispose] falls back to it unawaited for screens that never
  /// had a leave. Both can happen to one screen, and disposing a released
  /// media_kit `Player` twice is an `AssertionError`, so the future is kept.
  ///
  /// **The quit is dispatched before anything is awaited** (an enqueue on
  /// mpv's dispatch queue and nothing else). Neither half may throw out of
  /// here: a refused quit and a failed release are each worth a line, and
  /// the streams are closed before the release so a failed release skips
  /// nothing.
  Future<void> _endPlayback() => _teardown ??= _runTeardown();

  /// The body of [_endPlayback], separate only so that the memo above it
  /// stays a single line.
  Future<void> _runTeardown() async {
    final engine = _engine;
    final started = DateTime.now();
    // The only instrument: nothing is escalated to when it fires (the quit
    // below is the kill); it logs that a player that should have stopped in
    // a fraction of a second has not. Armed here rather than by the waiting
    // screen so it covers the hand-over too.
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
