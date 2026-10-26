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
  /// The top bar builds Next, Subtitles and Audio only when there is something
  /// behind them, so the focused button can vanish mid-playback. Focus is then
  /// on a detached node, the controls' scope is not told, and the video's spent
  /// `autofocus` never takes it back, so [_onKeyEvent] would stop running for
  /// good. [_focusNode] wraps the whole screen, so "nothing here has focus" is
  /// `!_focusNode.hasFocus`. A sheet this screen opened keeps the remote.
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
  /// A node whose widget is not built has no context and cannot take focus;
  /// asking anyway leaves the remote pointing at nothing. What is drawn
  /// depends on the width, on a receiver having the stream, and on whether
  /// there is a video yet.
  bool _focusStop(FocusNode node) {
    if (node.context == null) return false;
    node.requestFocus();
    return true;
  }

  /// The player's home stop: play/pause, wherever this layout put it. That is
  /// the bottom bar's transport, or the cast panel's while a receiver has the
  /// stream.
  bool _focusPlayPause() => _focusStop(_playPauseFocus);

  /// Moves focus up onto the shown controls: the top bar, which is built
  /// whatever else is on screen. False when it is not there, leaving the
  /// key to whatever it means otherwise.
  bool _focusUp() => _focusStop(_topBarFocus);

  /// Where a down press goes: the seek bar, and play/pause from the seek bar
  /// itself, so from anywhere on the OSD the seek bar is one press away and
  /// play/pause two.
  ///
  /// Named rather than measured: Flutter's directional traversal ranks by
  /// distance, so a narrow control near the source beats the obvious one,
  /// and "down always reaches play/pause" cannot be left to that.
  ///
  /// While the up-next countdown runs, down is "Play now" and the card keeps
  /// the remote until answered ([_moveWithinControls]). A stop this layout
  /// did not draw (the narrow layout's transport, no bottom bar while the
  /// stream resolves) leaves a focused control where it is and sends the
  /// remote from the video to the top bar, which is always built.
  void _focusDown() {
    final stop = _upNext.secondsLeft != null
        ? _playNextFocus
        : _seekBarFocus.hasFocus
        ? _playPauseFocus
        : _seekBarFocus;
    if (_focusStop(stop)) return;
    if (_controlFocused) return;
    _focusUp();
  }

  /// Up with a control focused: the next stop above inside the bar, and nothing
  /// at its edges. Inside the timing panel either direction moves, confined to
  /// the panel's own scope. Down on the bar has named stops instead
  /// ([_focusDown]).
  ///
  /// Neither wraps round nor steps out onto the video, which draws no focus
  /// ring and so is not a legitimate stop while something visible is on
  /// screen. Back is the way out of the controls ([_popBack]).
  void _moveWithinControls(TraversalDirection direction) {
    FocusManager.instance.primaryFocus?.focusInDirection(direction);
  }

  /// Whether Back has something to put away before it leaves the player:
  /// the timing panel first, then the up-next card, then a control bar that
  /// is up and free to go.
  ///
  /// The timing panel is a rung off a television too. It does not fade, so on a
  /// phone Back is the only way out, and on a desktop Escape comes down the
  /// same ladder. The other two are television-only; elsewhere Back and Escape
  /// leave the player. A bar that cannot fade (paused, buffering, a menu open)
  /// is not a rung: Back could do nothing about it, so it leaves.
  bool get _backDismisses =>
      _timingShown ||
      (_isTv &&
          (_upNext.secondsLeft != null || (_controls.visible && _canAutoHide)));

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
    if (_upNext.secondsLeft != null) {
      _upNext.dismiss();
      return;
    }
    _controls.hide();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // The screen is only still here to hold the picture up while the player
    // stops. Nothing it offers is aimed at anything any more, and media_kit
    // throws on a player it has released. So a late press is swallowed rather
    // than passed on, Back included, since leaving is what is already
    // happening.
    if (_leaving) return KeyEventResult.handled;
    // Back belongs to the route, not to this handler. Android delivers it as a
    // key first and pops only if nothing took it, and [PopScope] is what
    // answers. This sits above `_controls.show` below, because the OSD flashing
    // up on the way out of the player would be the opposite of what the press
    // asked for.
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

    // The timing panel is a layer of its own with focus of its own. The
    // direction keys walk its buttons, select presses one (its own handler has
    // already had the key by the time this runs), Escape closes it and Back
    // comes down the ladder below. None of them are the player's while it is
    // up, and none of them bring the OSD back either. Adjusting means watching
    // the picture between presses, and a bar flashing up on every one of them
    // is the opposite of that. Everything else still means what it always did.
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

    // Which of the player's two modes this press is in, read before
    // [ControlsVisibility.show]: a press means what it meant when the viewer made it.
    // A press landing as the bar fades gets either answer, and both are
    // fine.
    final shownBefore = _controls.shown;
    _controls.show();

    // A control on the bar has the remote: select presses it and left/right
    // walk the bar (the seek bar seeks), both handled below us. The seek bar
    // is not a button, so select there falls through to play/pause below.
    // Up walks the stops as drawn; down is the way back to the two controls
    // that matter ([_focusDown]).
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
          // With nothing drawn the press cannot be aiming: it is the one button
          // a hidden player has, play/pause. The bar only fades while playing
          // ([_canAutoHide]), so this stops the film and leaves the remote on
          // play/pause. The second press of the same key then restarts it. The
          // stopped playback keeps the bar up; until the engine reports the
          // pause, the ordinary [PlayerScreen.controlsTimeout] runs.
          _togglePlay();
          _focusPlayPause();
        } else if (_upNext.secondsLeft != null) {
          // On the video the centre key is the tap that [_onVideoTap]
          // handles, so with the countdown up it calls the hand-off off
          // instead of toggling playback.
          _upNext.dismiss();
        } else {
          _togglePlay();
        }
      }
      return KeyEventResult.handled;
    }

    // Up and down on a TV reach the controls (the television has its own volume
    // keys). Both stops are named ([_focusDown], [_focusUp]), so a press on a
    // hidden OSD brings the bar up with the remote already on the seek bar or
    // the top bar. Nothing invisible is ever walked. Left and right scan
    // whether the bar is up or not (the switch below).
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

    final shortcut = PlayerShortcut.of(key, shift: shift);
    if (shortcut == null) return KeyEventResult.ignored;
    if (!shortcut.repeats && event is! KeyDownEvent) {
      return KeyEventResult.handled;
    }
    switch (shortcut) {
      case PlayerShortcut.togglePlay:
        _togglePlay();
      case PlayerShortcut.play:
        _play();
      case PlayerShortcut.pause:
        _pause();
      case PlayerShortcut.stop:
        // Stop ends the session: leave the player (unloading pauses and reports
        // the position).
        _leavePlayer();
      case PlayerShortcut.seekBack:
        _seekBy(-_seekHold.stepFor(event, _seekStep));
      case PlayerShortcut.seekForward:
        _seekBy(_seekHold.stepFor(event, _seekStep));
      case PlayerShortcut.shortSeekBack || PlayerShortcut.shortSeekForward:
        // The short step stays an exact seek: at three seconds by default it
        // is shorter than many releases' keyframe interval, so a scan would
        // answer it with a jump of ten.
        _seekTo(
          _position.value +
              (shortcut == PlayerShortcut.shortSeekBack
                  ? -_shortSeekStep
                  : _shortSeekStep),
        );
      case PlayerShortcut.volumeUp:
        _setVolume(_volume + 5);
      case PlayerShortcut.volumeDown:
        _setVolume(_volume - 5);
      case PlayerShortcut.mute:
        _toggleMute();
      case PlayerShortcut.fullscreen:
        _toggleFullscreen();
      case PlayerShortcut.escape:
        // `escExitFullscreen` only decides whether Esc leaves fullscreen
        // first; otherwise it leaves the player, as in stremio-web.
        if (!_isTv && _fullscreenOn && _settings.escExitFullscreen) {
          _toggleFullscreen();
        } else {
          Navigator.of(context).maybePop();
        }
      case PlayerShortcut.subtitles:
        _openSubtitleMenu();
      case PlayerShortcut.subtitleTiming:
        _toggleSubtitleTiming();
      case PlayerShortcut.audio:
        if (_tracks.value.audio.length > 1) _openAudioMenu();
      case PlayerShortcut.next:
        // Not while casting, like the top bar's Next: moving on would
        // start the next episode here while the receiver plays this one.
        if (_state?.nextVideo != null && !_casting) _playNext();
      case PlayerShortcut.restart:
        _seekTo(Duration.zero);
      case PlayerShortcut.stats:
        if (ModalRoute.of(context)?.isCurrent ?? true) _toggleStatsPinned();
    }
    return KeyEventResult.handled;
  }

  // --- Stats hover ---------------------------------------------------------

  void _onPointerMoved() {
    // A hover still arrives while the player is stopping (the `MouseRegion` is
    // above the `IgnorePointer`), and it is aimed at nothing, like a key press
    // ([_onKeyEvent]). The timer below would also outlive [_detach].
    if (_leaving) return;
    _controls.show();
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
