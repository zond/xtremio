part of 'player_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// The up-next card, and handing over to the next episode.
extension _PlayerNextEpisode on _PlayerScreenState {
  // --- Next episode --------------------------------------------------------

  /// Shows the up-next card with the full `nextVideoNotificationDuration`
  /// countdown and starts it ticking (once no sheet is open; see
  /// [_showSheet]). A duration of 0 ("disabled") shows no card: the next
  /// episode plays as soon as this one ends.
  void _startUpNext() {
    final millis = _settings.nextVideoNotificationDuration;
    setState(() => _upNextSecondsLeft = (millis / 1000).ceil());
    _resumeUpNext();
  }

  /// Ticks the countdown once a second while the card shows and no sheet
  /// is open; at zero the next episode plays.
  void _resumeUpNext() {
    _pauseUpNext();
    final left = _upNextSecondsLeft;
    if (left == null || _menuOpen) return;
    if (left <= 0) {
      _playNext();
      return;
    }
    _upNextTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = _upNextSecondsLeft;
      if (!mounted || left == null) return;
      if (left <= 1) {
        _playNext();
      } else {
        setState(() => _upNextSecondsLeft = left - 1);
      }
    });
  }

  /// Stops the ticking but keeps the card and the seconds left on it.
  void _pauseUpNext() {
    _upNextTimer?.cancel();
    _upNextTimer = null;
  }

  void _dismissUpNext() {
    _pauseUpNext();
    if (_upNextSecondsLeft != null && mounted) {
      setState(() => _upNextSecondsLeft = null);
    }
  }

  /// Moves on to the next episode: the engine advances the library item,
  /// and either a new player takes this one's place, or we return to the
  /// details screen pointing at the episode so its streams can be picked.
  ///
  /// The new player gets, in order: a finished download of that episode
  /// (the better source, and the only one offline), its linked Drive file
  /// (the engine cannot find one: a Drive play's request names a service
  /// that answers no addon query, [driveStreamRequest]), or the stream the
  /// engine found (same addon, same binge group). [_advancing] holds a
  /// second press while the registry answers.
  void _playNext() {
    final state = _state;
    final next = state?.nextVideo;
    // Nothing to move on to (the next episode has gone from the state):
    // the countdown must not keep ticking.
    _dismissUpNext();
    if (state == null || next == null || _handedOver || _advancing) return;
    if (_leaving) return;
    _advancing = true;
    _client?.dispatch(CoreActions.playerNextVideo());
    final navigator = Navigator.of(context);
    // Whatever sits over this screen (a sheet) goes first, so that the
    // pop/replacement below acts on the player's own route.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      navigator.popUntil((candidate) => candidate == route);
    }
    final downloads = DownloadsScope.maybeOf(context);
    final drive = DriveAccountScope.maybeOf(context);
    final metaRequest = state.metaRequest ?? widget.metaRequest;
    if (metaRequest == null || (downloads == null && drive == null)) {
      _handOver(navigator, state, next, state.nextStream?.json);
      return;
    }
    unawaited(
      _handOverFromOwnCopy(
        navigator,
        downloads,
        drive,
        metaRequest,
        state,
        next,
      ),
    );
  }

  /// Hands over to the next episode's own file when the registry has a
  /// finished download of it, to its linked Drive file when there is one
  /// that opens, and to whatever the engine found otherwise.
  Future<void> _handOverFromOwnCopy(
    NavigatorState navigator,
    DownloadsClient? downloads,
    DriveAccount? drive,
    ResourceRequest metaRequest,
    PlayerState state,
    VideoInfo next,
  ) async {
    final metaId = metaRequest.path.id;
    if (downloads != null) {
      final playback = await offlinePlaybackOf(downloads, metaId, next.id);
      // Gone, or leaving, while the registry was answering: there is no
      // route left to replace, and a screen waiting for its own teardown
      // must not put a second player over itself -- a second engine and a
      // fresh open, from a press that asked to stop watching.
      if (!_stillOurs) return;
      if (playback != null) {
        _handOver(navigator, state, next, playback);
        return;
      }
    }
    final linked = drive?.files.matching(metaId, videoId: next.id);
    if (drive != null && linked != null && linked.isNotEmpty) {
      final file = linked.first;
      final opened = await openLinkedDriveFile(
        account: drive,
        file: file,
        opener: widget.driveOpener,
      );
      // The same two reasons as the registry's round trip above.
      if (!_stillOurs) return;
      if (opened is DriveFilePlayable) {
        _handOver(
          navigator,
          state,
          next,
          driveStreamJson(file: file, playable: opened),
          streamRequest: driveStreamRequest(
            type: metaRequest.path.type,
            videoId: next.id,
          ),
        );
        return;
      }
    }
    _handOver(navigator, state, next, state.nextStream?.json);
  }

  /// Puts a player for [next] in this screen's place, or -- with no
  /// [stream] anywhere for it -- goes back to the caller pointing at the
  /// episode so its streams can be picked.
  ///
  /// The new player's stream request is this one's with the id moved on,
  /// unless [streamRequest] names the one [stream] really came from: a
  /// Drive file found for the next episode is not the addon this episode
  /// played from.
  void _handOver(
    NavigatorState navigator,
    PlayerState state,
    VideoInfo next,
    Map<String, dynamic>? stream, {
    ResourceRequest? streamRequest,
  }) {
    if (stream == null) {
      // A leave like any other, and it takes the same road out: this
      // player is over, and the screen it goes back to would rather have
      // its answer a fraction of a second late than have mpv still
      // reading behind it.
      unawaited(_leave(PlayerScreenResult(selectVideoId: next.id)));
      return;
    }
    _handedOver = true;
    DiagnosticsLog.info('player', 'handing over to the next episode');
    // Before the push, not in [dispose]. `pushReplacement` keeps this
    // screen alive until the transition finishes, and the new player can
    // read its file's rate and ask for it inside that -- an already
    // downloaded episode opens at once -- whereupon this screen's dispose
    // would clear the ask the successor had just made. Nothing is left
    // holding a rate either way, because the release comes first.
    _releaseDisplayFrameRate();
    final current = state.streamRequest ?? widget.streamRequest;
    final subtitlesPath = state.subtitlesPath ?? widget.subtitlesPath;
    navigator.pushReplacement(
      MaterialPageRoute<PlayerScreenResult>(
        settings: const RouteSettings(name: PlayerScreen.routeName),
        builder: (_) => PlayerScreen(
          stream: stream,
          streamRequest:
              streamRequest ??
              current?.copyWith(path: current.path.copyWith(id: next.id)),
          metaRequest: state.metaRequest ?? widget.metaRequest,
          subtitlesPath: subtitlesPath?.copyWith(id: next.id),
          driveOpener: widget.driveOpener,
        ),
      ),
    );
  }
}
