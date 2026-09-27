part of 'player_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// The remote and the keyboard: focus stops, the Back ladder, key presses,
/// and pointer hover.
extension _PlayerKeys on _PlayerScreenState {
  /// After every rebuild on a television: takes the remote back onto the
  /// video when the control it was on has left the tree.
  ///
  /// The top bar builds Next, Subtitles and Audio only when there is
  /// something behind them, so the button holding the remote can vanish
  /// mid-playback (the engine reports the last episode, the second audio
  /// track goes away). Focus is then on a node that is no longer in the
  /// tree — the controls' scope is not told, so its listener cannot be
  /// the hook — and the video's [Focus] never gets it back, its
  /// `autofocus` having been spent when it first attached. [_onKeyEvent]
  /// would stop running for good: the remote dead and the controls stuck
  /// at full opacity until the player is left.
  ///
  /// [_focusNode] wraps the whole screen, so "nothing here has focus" is
  /// exactly `!_focusNode.hasFocus`. A sheet this screen opened keeps the
  /// remote, as the player is not the current route while it is up.
  void _scheduleFocusCheck() {
    if (_focusCheckScheduled) return;
    _focusCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusCheckScheduled = false;
      if (!mounted || !_isTv || _focusNode.hasFocus) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      _focusNode.requestFocus();
    });
  }

  /// The remote is on a control (the bar or the up-next card) rather than
  /// on the video.
  bool get _controlFocused =>
      _isTv && (_controlsScope.hasFocus || _upNextScope.hasFocus);

  // --- Keyboard ------------------------------------------------------------

  /// Focuses [node] where this layout drew it, and says whether it did.
  ///
  /// A node whose widget is not built has no context, and a node with no
  /// context cannot take focus: asking anyway leaves the remote pointing
  /// at nothing at all. Every named stop below goes through here for that
  /// reason -- what the player draws depends on the width, on whether a
  /// receiver has the stream, and on whether there is a video yet.
  bool _focusStop(FocusNode node) {
    if (node.context == null) return false;
    node.requestFocus();
    return true;
  }

  /// The player's home stop: play/pause, wherever this layout put it --
  /// the bottom bar's transport, or the cast panel's while a receiver has
  /// the stream.
  bool _focusPlayPause() => _focusStop(_playPauseFocus);

  /// Moves focus up onto the shown controls: the top bar, which is built
  /// whatever else is on screen. False when it is not there, leaving the
  /// key to whatever it means otherwise.
  bool _focusUp() => _focusStop(_topBarFocus);

  /// Where a down press goes: the seek bar, and play/pause from the seek
  /// bar itself.
  ///
  /// Two named stops, and every down press lands on one of them -- so
  /// from anywhere on the OSD the seek bar is one press away and
  /// play/pause is two, whatever this layout drew. That is the point: on
  /// a remote the useful control is the one that can always be got back
  /// to, and play/pause is this screen's.
  ///
  /// Named rather than measured. Flutter's directional traversal ranks
  /// candidates by distance, so a narrow control near the source beats a
  /// wide obvious one: down from the transport row reached whichever
  /// button happened to lie under it, and where down went from the top
  /// bar depended on how long the title was. "Down always reaches
  /// play/pause" cannot be left to that.
  ///
  /// The countdown is the exception, because it is the decision in front
  /// of the viewer: while it runs, down is "Play now" and the card keeps
  /// the remote until the viewer answers it ([_moveWithinControls]).
  ///
  /// The fallbacks are the layouts that leave a stop out: the narrow one
  /// puts the transport in the middle of the video with no node of its
  /// own, and there is no bottom bar at all while the stream is still
  /// resolving. A press that finds its stop undrawn stays where it is if
  /// a control already has the remote -- an edge press moves nothing,
  /// which is what the rest of the bar does at its edges -- and from the
  /// video falls back to the top bar, which is always built.
  void _focusDown() {
    final stop = _upNextSecondsLeft != null
        ? _playNextFocus
        : _seekBarFocus.hasFocus
        ? _playPauseFocus
        : _seekBarFocus;
    if (_focusStop(stop)) return;
    if (_controlFocused) return;
    _focusUp();
  }

  /// Up with a control focused: the next stop above inside the bar -- or
  /// either direction inside the timing panel, which is confined to its
  /// own scope for the same reason -- and nothing at all at its edges.
  ///
  /// Down does not come through here on the bar; it has named stops
  /// instead ([_focusDown]).
  ///
  /// Neither wrapping round nor stepping out onto the video. The video
  /// draws no focus ring, so it cannot be a legitimate stop while
  /// something visible is on screen, and a viewer who is not looking
  /// closely would only see the ring vanish. Back is the way out of the
  /// controls (see [_popBack]).
  void _moveWithinControls(TraversalDirection direction) {
    FocusManager.instance.primaryFocus?.focusInDirection(direction);
  }

  /// Whether Back has something to put away before it leaves the player:
  /// the timing panel first, then the up-next card, then a control bar
  /// that is up and free to go.
  ///
  /// The panel is the one rung that exists off a television too. It is
  /// opened deliberately and it does not fade, so on a phone Back is the
  /// only way out of it and on a desktop Escape comes down the same
  /// ladder; the other two are the OSD's, where the pointer hides the
  /// controls and Escape means what `escExitFullscreen` says it means, so
  /// Back and Escape keep leaving the player as they always have.
  ///
  /// A bar that cannot fade -- paused, buffering, a menu open -- is not on
  /// the ladder: there is nothing Back could do about it, so it leaves the
  /// player instead of appearing to do nothing.
  bool get _backDismisses =>
      _timingShown ||
      (_isTv &&
          (_upNextSecondsLeft != null || (_controlsVisible && _canAutoHide)));

  /// One rung down the ladder [_backDismisses] describes, most transient
  /// first. Only called while there is a rung to take: the last one is
  /// leaving the player, and [build]'s `PopScope` sends that to
  /// [_leavePlayer] instead, because a pop the framework makes for us
  /// would take the route out from under a player that is still reading.
  void _popBack() {
    if (_timingShown) {
      _hideSubtitleTiming();
      return;
    }
    if (_upNextSecondsLeft != null) {
      _dismissUpNext();
      return;
    }
    _hideControls();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // The screen is only still here to hold the picture up while the
    // player stops. Nothing it offers is aimed at anything any more, and
    // media_kit throws on a player it has released, so a late press is
    // swallowed rather than passed on -- Back included, since leaving is
    // what is already happening.
    if (_leaving) return KeyEventResult.handled;
    // Back belongs to the route, not to this handler: Android delivers it
    // as a key first and pops only if nothing took it, and [PopScope] is
    // what answers. Above `_showControls` below, because the OSD flashing
    // up on the way out of the player would be the opposite of what the
    // press asked for.
    if (event.logicalKey == LogicalKeyboardKey.goBack) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final shift = keyboard.isShiftPressed;

    // The timing panel is a layer of its own with focus of its own: the
    // direction keys walk its buttons, select presses one (its own
    // handler has already had the key by the time this runs), Escape
    // closes it and Back comes down the ladder below. None of them are
    // the player's while it is up, and none of them bring the OSD back
    // either -- adjusting means watching the picture between presses,
    // and a bar flashing up on every one of them is the opposite of
    // that. Everything else still means what it always did.
    if (_timingScope.hasFocus) {
      if (key == LogicalKeyboardKey.escape) {
        if (event is KeyDownEvent) _hideSubtitleTiming();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown) {
        if (event is KeyDownEvent) {
          _moveWithinControls(
            key == LogicalKeyboardKey.arrowUp
                ? TraversalDirection.up
                : TraversalDirection.down,
          );
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.tab ||
          RemotePress.activateKeys.contains(key)) {
        // The panel's own traversal, and its own buttons.
        return KeyEventResult.ignored;
      }
    }

    // Which of the player's two modes this press is in, read here and used
    // below: with the OSD up there is something to aim at and the press is
    // aimed, and with it hidden there is not. Read before [_showControls],
    // because a press means what it meant when the viewer made it.
    //
    // Whatever the state is when the key arrives is the state, including
    // the instant the bar is on its way out: a press that lands then gets
    // whichever of the two answers this reading gives, and both are fine
    // -- the control the viewer was on, or play/pause. Nothing here tries
    // to tell those apart.
    final shownBefore = _controlsShown;
    _showControls();

    // A control on the bar has the remote: select presses it and left/right
    // walk the bar (the seek bar seeks; both are handled below us, before
    // this ever runs). Up and down leave the control, and the bar itself.
    // The seek bar is the exception to select: it is not a button, so the
    // key falls through to the play/pause below.
    //
    // The two directions are not symmetrical, and that is deliberate. Up
    // walks the stops as they are drawn, which is what reading the bar
    // upwards looks like. Down is the way back to the two controls that
    // matter ([_focusDown]), from any stop and in at most two presses.
    if (_controlFocused) {
      if (key == LogicalKeyboardKey.arrowDown) {
        if (event is KeyDownEvent) _focusDown();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        if (event is KeyDownEvent) _moveWithinControls(TraversalDirection.up);
        return KeyEventResult.handled;
      }
      if ((RemotePress.activateKeys.contains(key) && !_seekBarFocus.hasFocus) ||
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.tab) {
        return KeyEventResult.ignored;
      }
    }

    // The remote's centre key (and Enter, a gamepad's A) on a TV. Off a TV
    // these keys keep their default meaning (nothing, on the video
    // itself).
    if (RemotePress.activateKeys.contains(key)) {
      if (!_isTv) return KeyEventResult.ignored;
      if (event is KeyDownEvent) {
        if (!shownBefore) {
          // With nothing drawn there is nothing to aim at, so the press
          // cannot be about aiming: it is the one button a hidden player
          // has, and it means play/pause. The bar only fades while
          // something is playing ([_canAutoHide]), so this is the press
          // that stops the film -- and it leaves the remote on play/pause,
          // which makes the second press of the same key the one that
          // starts it again, with no hunting for a button in between.
          //
          // Nothing special is done about the fade. What keeps the bar up
          // is the stopped playback itself -- [_canAutoHide] is false for
          // as long as it lasts, so no timer is armed and [_hideControls]
          // refuses -- and that begins the moment the engine reports the
          // pause, milliseconds away. Until then the ordinary
          // [PlayerScreen.controlsTimeout] runs, as it does after any
          // press: a player that turns out not to have paused should not
          // behave as though it had.
          _togglePlay();
          _focusPlayPause();
        } else if (_upNextSecondsLeft != null) {
          // On the video the centre key is the tap that [_onVideoTap]
          // handles, so with the countdown up it calls the hand-off off
          // instead of toggling playback.
          _dismissUpNext();
        } else {
          _togglePlay();
        }
      }
      return KeyEventResult.handled;
    }

    // Up and down on a TV are how the remote reaches the controls; the
    // television has its own volume keys, so they never fall through to
    // the volume there.
    //
    // A hidden OSD is no longer a wasted press. Both stops are named
    // ([_focusDown], [_focusUp]) rather than measured from wherever focus
    // happens to be, so the viewer knows where the press lands before they
    // make it and can be shown it in the same press: the bar comes up
    // (above) with the remote already on the seek bar, or on the top bar.
    // Nothing invisible is ever walked -- there is one stop, and it is
    // drawn by the time the frame is.
    //
    // Left and right are the other two, and they are not moves at all:
    // they scan, which is what they mean on the video whether the bar is
    // up or not, and the bar comes up showing where the scan went (the
    // switch at the end of this method).
    if (_isTv &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      if (event is! KeyDownEvent) return KeyEventResult.handled;
      if (key == LogicalKeyboardKey.arrowDown) {
        _focusDown();
      } else {
        _focusUp();
      }
      return KeyEventResult.handled;
    }

    // Shift+I toggles the stats OSD, as in mpv; only the initial press.
    if (key == LogicalKeyboardKey.keyI) {
      if (!shift) return KeyEventResult.ignored;
      if (event is KeyDownEvent &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        _toggleStatsPinned();
      }
      return KeyEventResult.handled;
    }
    if (shift &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      // The short step is the precise one and stays an exact seek. It is
      // three seconds by default, which is shorter than the gap between
      // one keyframe and the next on a great many releases, so a scan
      // would answer a press for three seconds with a jump of ten -- and
      // this is the key a viewer reaches for when the step is too coarse
      // already.
      _seekTo(
        _position.value +
            (key == LogicalKeyboardKey.arrowLeft
                ? -_shortSeekStep
                : _shortSeekStep),
      );
      return KeyEventResult.handled;
    }
    switch (key) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.keyK:
      case LogicalKeyboardKey.mediaPlayPause:
        if (event is KeyDownEvent) _togglePlay();
      case LogicalKeyboardKey.mediaPlay:
        if (event is KeyDownEvent) _play();
      case LogicalKeyboardKey.mediaPause:
        if (event is KeyDownEvent) _pause();
      case LogicalKeyboardKey.mediaStop:
        // Stop ends the session: leave the player (unloading pauses and
        // reports the position). Unlike Back it has no ladder to come down
        // first -- there is nothing transient about a stop.
        if (event is KeyDownEvent) _leavePlayer();
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyJ:
      case LogicalKeyboardKey.mediaRewind:
        _seekBy(-_seekHold.stepFor(event, _seekStep));
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyL:
      case LogicalKeyboardKey.mediaFastForward:
        _seekBy(_seekHold.stepFor(event, _seekStep));
      case LogicalKeyboardKey.arrowUp:
        _setVolume(_volume + 5);
      case LogicalKeyboardKey.arrowDown:
        _setVolume(_volume - 5);
      case LogicalKeyboardKey.keyM:
        if (event is KeyDownEvent) _toggleMute();
      case LogicalKeyboardKey.keyF:
        if (event is KeyDownEvent) _toggleFullscreen();
      case LogicalKeyboardKey.escape:
        if (event is! KeyDownEvent) break;
        // `escExitFullscreen` only decides whether Esc leaves fullscreen
        // first; otherwise it leaves the player, as in stremio-web.
        if (!_isTv && _fullscreenOn && _settings.escExitFullscreen) {
          _toggleFullscreen();
        } else {
          Navigator.of(context).maybePop();
        }
      case LogicalKeyboardKey.keyS:
        // S is the list of subtitles; Shift+S is what to do about the
        // one that is playing.
        if (event is! KeyDownEvent) break;
        if (shift) {
          _toggleSubtitleTiming();
        } else {
          _openSubtitleMenu();
        }
      case LogicalKeyboardKey.keyA:
        if (event is KeyDownEvent && _tracks.value.audio.length > 1) {
          _openAudioMenu();
        }
      case LogicalKeyboardKey.keyN:
      case LogicalKeyboardKey.mediaTrackNext:
        // Not while casting, like the top bar's Next: moving on would
        // start the next episode here while the receiver plays this one.
        if (event is KeyDownEvent && _state?.nextVideo != null && !_casting) {
          _playNext();
        }
      case LogicalKeyboardKey.mediaTrackPrevious:
        // There is no previous episode in the player's state; the remote's
        // previous-track key starts this one over, as music players do.
        if (event is KeyDownEvent) _seekTo(Duration.zero);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // --- Stats hover ---------------------------------------------------------

  void _onPointerMoved() {
    // The `MouseRegion` sits above the `IgnorePointer` that covers the
    // rest of the screen ([build]), so a hover still arrives while the
    // player is stopping. It is aimed at nothing, exactly as a key press
    // is ([_onKeyEvent]): bringing the OSD back over a picture on its way
    // out is the opposite of what the viewer asked for, and the timer
    // below would be armed after [_detach] had run.
    if (_leaving) return;
    _showControls();
    _statsHoverTimer?.cancel();
    _statsHoverTimer = Timer(PlayerScreen.statsHoverTimeout, () {
      if (!mounted || !_statsHover) return;
      setState(() => _statsHover = false);
      _syncStatsPolls();
    });
    if (!_statsHover) {
      setState(() => _statsHover = true);
      _syncStatsPolls();
    }
  }

  void _onPointerLeft() {
    _statsHoverTimer?.cancel();
    _statsHoverTimer = null;
    if (!_statsHover) return;
    setState(() => _statsHover = false);
    _syncStatsPolls();
  }
}
