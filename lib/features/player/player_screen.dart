import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/core.dart';
import 'playback_engine.dart';

/// Plays one stream.
///
/// Dispatches `Load Player` for [stream], waits for the engine to resolve it
/// (`player.stream` becomes `Ready` with a `streaming_url`: the direct URL
/// for HTTP streams, the embedded stream-server's URL for torrents), opens
/// that URL in the [PlaybackEngine], and reports progress back so the
/// library and continue-watching stay in sync. Unloads on dispose.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.stream,
    this.streamRequest,
    this.metaRequest,
  });

  /// Raw stream JSON as it came out of `meta_details.streams` (or a
  /// hand-built one; see the dev entries in Settings).
  final Map<String, dynamic> stream;

  /// The addon request the stream came from, when known.
  final ResourceRequest? streamRequest;

  /// The meta request, so the engine tracks the library item / next video.
  final ResourceRequest? metaRequest;

  /// Minimum spacing of `TimeChanged` reports to the core.
  static const Duration timeReportInterval = Duration(seconds: 1);

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _player;
  PlaybackEngine? _engine;
  final List<StreamSubscription<void>> _subscriptions = [];

  Uri? _opened;
  Duration _duration = Duration.zero;
  Duration? _lastReported;
  bool? _lastPlaying;
  bool _buffering = false;
  String? _engineError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_client != null) return;
    final client = CoreScope.of(context);
    _client = client;
    _player = CoreFieldNotifier(client, CoreField.player)
      ..addListener(_onPlayerState);
    client.dispatch(
      CoreActions.loadPlayer(
        stream: widget.stream,
        streamRequest: widget.streamRequest,
        metaRequest: widget.metaRequest,
      ),
    );

    final engine = PlaybackScope.of(context)();
    _engine = engine;
    _subscriptions.addAll([
      engine.duration.listen((d) => _duration = d),
      engine.position.listen(_onPosition),
      engine.playing.listen(_onPlaying),
      engine.completed.listen(_onCompleted),
      engine.buffering.listen((b) => setState(() => _buffering = b)),
      engine.errors.listen((e) => setState(() => _engineError = e)),
    ]);
  }

  PlayerState? get _state {
    final json = _player?.value;
    return json == null ? null : PlayerState.fromJson(json);
  }

  void _onPlayerState() {
    final state = _state;
    final url = state?.streamingUrl;
    if (state == null || url == null || url == _opened) {
      if (mounted) setState(() {});
      return;
    }
    _opened = url;
    final progress = state.progress;
    final start = progress != null && progress.isResumable
        ? Duration(milliseconds: progress.timeOffset)
        : Duration.zero;
    _engine?.open(url, start: start).catchError((Object error) {
      if (mounted) setState(() => _engineError = '$error');
    });
    if (mounted) setState(() => _engineError = null);
  }

  String get _device => Platform.operatingSystem;

  void _onPosition(Duration position) {
    if (_opened == null || _duration == Duration.zero) return;
    final last = _lastReported;
    if (last != null &&
        (position - last).abs() < PlayerScreen.timeReportInterval) {
      return;
    }
    _lastReported = position;
    _client?.dispatch(
      CoreActions.playerTimeChanged(
        time: position.inMilliseconds,
        duration: _duration.inMilliseconds,
        device: _device,
      ),
    );
  }

  void _onPlaying(bool playing) {
    if (_opened == null || playing == _lastPlaying) return;
    _lastPlaying = playing;
    _client?.dispatch(CoreActions.playerPausedChanged(!playing));
  }

  void _onCompleted(bool completed) {
    if (completed && _opened != null) {
      _client?.dispatch(CoreActions.playerEnded());
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    final engine = _engine;
    _engine = null;
    if (engine != null) _disposeAfterFrame(engine);
    _player?.removeListener(_onPlayerState);
    _player?.dispose();
    _client?.dispatch(CoreActions.unload(CoreField.player));
    super.dispose();
  }

  /// Releases [engine] two frames from now instead of synchronously here.
  ///
  /// This `dispose` runs while the frame that unmounts the video surface is
  /// being built, and the raster thread may still be drawing the previous
  /// frame, which references the video texture. media_kit unregisters and
  /// frees that texture from the platform thread as soon as `Player.dispose`
  /// reaches it, so disposing right away can free the texture under the
  /// raster thread (a SIGSEGV inside the engine on Linux, seen with
  /// media_kit's software-rendered texture).
  ///
  /// The engine's layer-tree pipeline holds at most two frames, so once the
  /// UI thread has produced a second frame the raster thread has finished
  /// the last one that showed the texture. [SchedulerBinding.endOfFrame]
  /// schedules a frame when none is pending, so this also works when called
  /// outside a frame.
  static void _disposeAfterFrame(PlaybackEngine engine) {
    Future<void> release() async {
      await SchedulerBinding.instance.endOfFrame;
      await SchedulerBinding.instance.endOfFrame;
      await engine.dispose();
    }

    release().ignore();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final engine = _engine;
    final status = _statusText(state);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (engine != null && _opened != null) engine.buildVideo(context),
          if (status != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_engineError == null && state?.unplayableReason == null)
                      const CircularProgressIndicator()
                    else
                      const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 12),
                    Text(status, textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          SafeArea(
            child: Row(
              children: [
                const BackButton(color: Colors.white),
                Expanded(
                  child: Text(
                    state?.title ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          if (_opened != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 4,
              child: Text(
                _opened.toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: Colors.white38),
              ),
            ),
        ],
      ),
    );
  }

  String? _statusText(PlayerState? state) {
    if (_engineError != null) return 'Playback failed: $_engineError';
    if (state == null || !state.isLoaded) return 'Loading…';
    final unplayable = state.unplayableReason;
    if (unplayable != null) return unplayable;
    if (_opened == null) return 'Resolving stream…';
    if (_buffering) {
      return state.selectedStream?.kind == StreamKind.torrent
          ? 'Buffering from the torrent…'
          : 'Buffering…';
    }
    return null;
  }
}
