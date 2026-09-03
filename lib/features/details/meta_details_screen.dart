import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/tv_density.dart';
import '../../widgets/download_badge.dart';
import '../../widgets/filter_controls.dart';
import '../../widgets/poster_tile.dart';
import '../../widgets/remote_press.dart';
import '../../widgets/shared_field_screen.dart';
import '../discover/discover_screen.dart';
import '../downloads/download_labels.dart';
import '../downloads/downloads_controller.dart';
import '../downloads/offline_play.dart';
import '../player/player_screen.dart';

/// One title: dispatches `Load MetaDetails` for [type]/[id] on mount and
/// shows the meta item, its episodes (for a series) and every stream the
/// installed addons return for the selected video.
///
/// The engine guesses the video to show streams for when it can (a movie,
/// or a `defaultVideoId`); for a series without one this screen picks the
/// first sensible episode itself and every episode tap re-`Load`s the field
/// with that video's stream path, so the streams list always follows the
/// selection. Tapping a playable stream opens the player.
///
/// Below [MetaDetailsScreen.wideBreakpoint] the streams are not beside the
/// episodes but far below them in the same scroll view, so a tap there has
/// to be answered where it happened: the tile goes selected at once, the
/// stream section is scrolled into view, and it says it is looking until
/// the engine answers with that episode's streams.
///
/// A torrent stream can also be taken offline: the tile's download button
/// pins it through the [DownloadsClient] with everything the play path
/// hands the player (the raw stream, both addon requests) plus a meta
/// snapshot, so Details and the Downloads screen render with no network.
/// The title goes into the library with it, because that is what makes the
/// player track progress while offline (a temp library item is not enough:
/// see `docs/phase3-design.md` on `library_item`). Playing that same
/// release afterwards plays the file on the device rather than streaming
/// it, connection or not (`offline_play.dart`).
///
/// On a TV the info column and the streams pane are separate
/// [FocusTraversalGroup]s, focus starts on the stream the user most likely
/// wants (the last used source, else the first playable one) as nothing
/// else on a freshly pushed screen holds any, the remote's menu key or a
/// held select on an episode is its long press (toggle watched), and a long
/// season list is picked from a [FilterMenu] rather than a dropdown.
class MetaDetailsScreen extends StatefulWidget {
  const MetaDetailsScreen({
    super.key,
    required this.type,
    required this.id,
    this.videoId,
  });

  final String type;
  final String id;

  /// The video to show streams for straight away (the continue-watching
  /// row knows it); without it the engine guesses, or the screen picks.
  final String? videoId;

  /// Above this width the streams sit in a side pane next to the details.
  static const double wideBreakpoint = 720;

  @override
  State<MetaDetailsScreen> createState() => _MetaDetailsScreenState();
}

/// Two of these screens can be on the stack at once (a genre chip opens
/// Discover, whose posters open another title), both on the one
/// `meta_details` field: see [SharedFieldScreen].
class _MetaDetailsScreenState extends State<MetaDetailsScreen>
    with SharedFieldScreen<MetaDetailsScreen, MetaDetailsState> {
  CoreClient? _client;
  CoreFieldNotifier? _details;

  /// The downloads, when the app put a client above this screen (it always
  /// does; a test that does not care about downloads need not). Null leaves
  /// the download affordances off the tiles entirely.
  DownloadsClient? _downloadsClient;
  DownloadsController? _downloads;

  /// The streams whose pin is in flight, by [_streamKey]. `add` blocks
  /// until the server takes the pin -- for a magnet, until its metadata
  /// resolves -- so a tapped tile has to say it is working.
  final Set<String> _pending = {};

  /// A play is between its tap and its player route. Held over the whole
  /// push, so the tile underneath the player cannot start a second one.
  bool _playing = false;

  /// The video of the last `Load` this screen dispatched (null lets the
  /// engine guess), so the field can be reloaded with the same selection.
  String? _requestedVideoId;

  /// Set once the screen has picked an episode on the engine's behalf (or
  /// was told which video to open), so a later state without a stream path
  /// (unload, another title) does not trigger it again.
  late bool _pickedInitialVideo = widget.videoId != null;

  /// The season the episode list shows; null until the user (or the
  /// selected episode) chooses one.
  int? _season;

  /// The episode a tap asked for while the engine has not answered with its
  /// streams yet. The field still describes the previous selection, so
  /// until it catches up the screen follows this instead: the tile is the
  /// selected one and the stream section says it is working, rather than
  /// listing another episode's streams under this episode's name.
  ///
  /// Only a tap sets it. The pick this screen makes on the engine's behalf
  /// (see [_maybePickInitialVideo]) is not a tap and gets no such feedback.
  String? _awaitingVideoId;

  /// The stream section's header, so a tap on an episode can scroll it into
  /// view on a layout where it sits below the episode list. It is only in
  /// the tree while the viewport has reached it: a sliver far below the
  /// fold is never built, which is why [_narrowScroll] is here too.
  final GlobalKey _streamsKey = GlobalKey();

  /// The one scroll view of the narrow layout, whose end is the stream
  /// section.
  final ScrollController _narrowScroll = ScrollController();

  /// What the last build laid out (see [MetaDetailsScreen.wideBreakpoint]).
  /// On a wide layout the streams are already beside the episodes, so
  /// nothing has to scroll.
  bool _isWide = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _details?.dispose();
      _client = client;
      _details = CoreFieldNotifier(client, CoreField.metaDetails)
        ..addListener(onFieldChanged);
      _load(widget.videoId);
    }
    final downloads = DownloadsScope.maybeOf(context);
    if (_downloadsClient != downloads) {
      _downloads
        ?..removeListener(_onDownloadsChanged)
        ..dispose();
      _downloadsClient = downloads;
      _downloads = downloads == null
          ? null
          : (DownloadsController(downloads)..addListener(_onDownloadsChanged));
    }
    trackRoute();
  }

  void _onDownloadsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    releaseField();
    _narrowScroll.dispose();
    _details?.dispose();
    _downloads
      ?..removeListener(_onDownloadsChanged)
      ..dispose();
    super.dispose();
  }

  @override
  CoreField get sharedField => CoreField.metaDetails;

  @override
  CoreClient? get coreClient => _client;

  @override
  CoreFieldNotifier? get fieldNotifier => _details;

  @override
  MetaDetailsState parseField(Map<String, dynamic> json) =>
      MetaDetailsState.fromJson(json);

  /// Its `metaPath` names this title (another title, or the unloaded field,
  /// does not).
  @override
  bool isOwnState(MetaDetailsState state) => state.metaPath?.id == widget.id;

  /// Back on top: load this title again with the selection it had.
  @override
  void reloadField() => _load(_requestedVideoId ?? ownState?.streamPath?.id);

  @override
  void didReceiveOwnState(MetaDetailsState state) {
    if (_awaitingVideoId != null && state.streamPath?.id == _awaitingVideoId) {
      // The answer to the tap: the section is no longer a spinner but the
      // streams themselves, so put it back at the top of the screen.
      _awaitingVideoId = null;
      _revealStreams(atEnd: false);
    }
    _maybePickInitialVideo(state);
  }

  /// The episode the screen shows as selected: the tap in flight, else the
  /// engine's own selection.
  String? _selectedVideoId(MetaDetailsState state) =>
      _awaitingVideoId ?? state.streamPath?.id;

  /// Whether the streams on screen are the previous selection's, because a
  /// tap has asked for another episode and nothing has come back yet.
  bool _isAwaitingStreams(MetaDetailsState state) =>
      _awaitingVideoId != null && state.streamPath?.id != _awaitingVideoId;

  MetaDetailsState? get _state => ownState;

  /// Dispatches `Load MetaDetails` for this title, showing [videoId]'s
  /// streams (or letting the engine guess), and takes the field over.
  void _load(String? videoId) {
    _requestedVideoId = videoId;
    _awaitingVideoId = null;
    claimField();
    _client?.dispatch(
      CoreActions.loadMetaDetails(
        type: widget.type,
        id: widget.id,
        videoId: videoId,
      ),
    );
  }

  /// Mirrors `selected_guess_stream_update`: when the engine will not pick a
  /// stream path for this title (a series without a default video), select
  /// the initial episode once the meta is in so streams load without a tap.
  void _maybePickInitialVideo(MetaDetailsState state) {
    if (_pickedInitialVideo) return;
    if (state.streamPath != null || state.engineWillGuessStream) return;
    final video = state.initialVideo(preferred: widget.videoId);
    if (video == null) return;
    _pickedInitialVideo = true;
    _selectVideo(video);
  }

  /// Shows [video]'s streams. [reveal] is a selection the user made (a tap
  /// on an episode, the player asking for the next one) rather than one the
  /// screen made for them, and on a narrow layout it is acknowledged where
  /// the user is looking. On a wide one there is nothing to acknowledge:
  /// the streams pane is beside the episode and answers for itself.
  void _selectVideo(VideoInfo video, {bool reveal = false}) {
    _load(video.id);
    final acknowledge = reveal && !_isWide;
    if (acknowledge) _awaitingVideoId = video.id;
    if (mounted) setState(() => _season = video.season);
    if (acknowledge) _revealStreams(atEnd: true);
  }

  /// Brings the stream section into view when it is not already beside the
  /// episode list. Below the breakpoint the two are one scroll view and the
  /// streams are far below the tap, so without this the screen looks as if
  /// nothing happened.
  ///
  /// It takes two goes, one per moment the user gets an answer, and they
  /// scroll differently because of what the viewport has laid out. On the
  /// tap the section is still below the fold: its header is in the tree but
  /// has no place in the viewport yet, so `ensureVisible` has nothing to
  /// measure and the scroll is to the end of the page instead -- which is
  /// the section, everything it holds while it waits fitting on a screen.
  /// Once the streams are in, the header is on screen and a real target:
  /// it goes to the top and the list fills the screen under it.
  ///
  /// Always after the frame the state change schedules, so it measures the
  /// section that is on its way in rather than the one going out.
  void _revealStreams({required bool atEnd}) {
    if (_isWide) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_narrowScroll.hasClients) return;
      const duration = Duration(milliseconds: 250);
      const curve = Curves.easeOut;
      final header = atEnd ? null : _streamsKey.currentContext;
      if (header == null) {
        _narrowScroll.animateTo(
          _narrowScroll.position.maxScrollExtent,
          duration: duration,
          curve: curve,
        );
      } else {
        Scrollable.ensureVisible(header, duration: duration, curve: curve);
      }
    });
  }

  /// Bookmark: `AddToLibrary` with the meta item as received, or
  /// `RemoveFromLibrary` by id. The engine refreshes `libraryItem` itself.
  void _toggleLibrary(MetaDetailsState state, MetaItem meta) {
    _client?.dispatch(
      state.isInLibrary
          ? CoreActions.removeFromLibrary(meta.id)
          : CoreActions.addToLibrary(meta.json),
    );
  }

  void _toggleWatched(MetaDetailsState state, VideoInfo video) {
    _client?.dispatch(
      CoreActions.markVideoAsWatched(
        video.json,
        watched: !state.isWatched(video),
      ),
    );
  }

  /// Opens the player on [stream] -- or on the file this device already
  /// holds of it.
  ///
  /// A finished download of *this* release is played from the disk even
  /// with a connection: there is nothing the server can add to a whole
  /// file. Only that release, though -- picking another stream tile is a
  /// request for that source, not for the copy on disk. The addon requests
  /// are the ones the picker has either way, which is what keeps
  /// continue-watching moving offline.
  ///
  /// A download whose file went away since it finished (an unplugged
  /// volume, a deletion from outside the app) streams instead and says so,
  /// rather than opening a player on a URL with no file behind it.
  ///
  /// Asking the registry is a round trip, so the tile stays tappable
  /// between the tap and the push: a second tap is dropped rather than
  /// pushing a second player, each of which would load the shared `player`
  /// field and start an engine of its own.
  Future<void> _play(
    MetaDetailsState state,
    StreamGroup group,
    StreamInfo stream,
  ) async {
    if (_playing) return;
    _playing = true;
    try {
      await _pushPlayer(state, group, stream);
    } finally {
      _playing = false;
    }
  }

  Future<void> _pushPlayer(
    MetaDetailsState state,
    StreamGroup group,
    StreamInfo stream,
  ) async {
    final videoId = state.streamPath?.id ?? state.meta?.id ?? widget.id;
    final client = _downloadsClient;
    final download = _videoDownload(videoId);
    OfflinePlayback playback = (stream: null, message: null);
    if (client != null &&
        download != null &&
        download.isComplete &&
        download.stream.isSameSource(stream)) {
      playback = await offlinePlayback(client, download);
      if (!mounted) return;
      final message = playback.message;
      if (message != null) _tell(message);
    }
    if (!mounted) return;
    final result = await Navigator.of(context).push<PlayerScreenResult>(
      MaterialPageRoute<PlayerScreenResult>(
        settings: const RouteSettings(name: 'player'),
        builder: (_) => PlayerScreen(
          stream: playback.stream ?? stream.json,
          streamRequest: group.request,
          metaRequest: state.metaRequest,
          subtitlesPath: ResourcePath(
            resource: 'subtitles',
            type: widget.type,
            id: videoId,
          ),
        ),
      ),
    );
    // The player wanted the next episode but had no stream for it: show
    // that episode's streams.
    if (result != null && mounted) _selectVideoId(result.selectVideoId);
  }

  /// Identifies one stream of one video while its pin is in flight. The
  /// state is reloaded while the call runs, so the tile the user tapped is
  /// a different widget by the time it comes back.
  static String _streamKey(String videoId, StreamInfo stream) =>
      '$videoId|${stream.infoHash}|${stream.fileIdx}';

  /// The download of one video, whatever source it was taken from. The
  /// registry is keyed by meta and video, so there is at most one, and a
  /// stream tile reads it two ways: as *its* download when the sources
  /// match, and as the download it would replace when they do not.
  DownloadView? _videoDownload(String videoId) =>
      _downloads?.forVideo(widget.id, videoId);

  /// Pins [stream] as an offline download of the selected video, and puts
  /// the title in the library so playing it offline still records progress.
  ///
  /// The library add waits for the pin: a refused one (a full disk) should
  /// not leave a title behind that the user never asked to keep. Whether it
  /// was in the library is read before the call, since the state this was
  /// built from is a moment old by the time the pin is taken.
  ///
  /// A finished download of the same video from another release is asked
  /// about first: the pin replaces it, and the Rust side deletes the file
  /// it replaced. Nothing undoes that, so it is not something a stray tap
  /// gets to do.
  Future<void> _download(
    MetaDetailsState state,
    MetaItem meta,
    StreamGroup group,
    StreamInfo stream,
  ) async {
    final client = _downloadsClient;
    final downloads = _downloads;
    if (client == null || downloads == null) return;
    final videoId = state.streamPath?.id ?? meta.id;
    // Asked before the tile goes busy: the dialog is modal, so it is the
    // guard against a second press while it stands, and a cancelled one
    // leaves the tile exactly as it was.
    final replaced = downloads.forVideo(widget.id, videoId);
    if (replaced != null &&
        replaced.isComplete &&
        !replaced.stream.isSameSource(stream)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _ReplaceDialog(replaced: replaced),
      );
      if (confirmed != true || !mounted) return;
    }
    final key = _streamKey(videoId, stream);
    if (!_pending.add(key)) return;
    setState(() {});
    final wasInLibrary = state.isInLibrary;
    final request = DownloadRequest(
      metaId: widget.id,
      videoId: videoId,
      type: widget.type,
      name: downloadName(meta, state.selectedVideo),
      poster: meta.poster,
      stream: stream,
      meta: meta.json,
      streamRequest: group.request.toJson(),
      metaRequest: state.metaRequest?.toJson(),
    );

    DownloadAddResult? result;
    Object? thrown;
    try {
      result = await client.add(request);
    } catch (error) {
      thrown = error;
    }
    if (!mounted) return;
    // The guard is held over the refresh as well: until the fresh listing
    // has the entry, the tile has nothing to show for the pin and would
    // offer the download again.
    await downloads.refresh();
    if (!mounted) return;
    setState(() => _pending.remove(key));

    if (thrown != null) {
      _tell('This stream could not be downloaded.');
      return;
    }
    final failure = result!.error;
    if (failure != null) {
      _tell(downloadFailureMessage(failure));
      return;
    }
    if (!wasInLibrary) {
      _client?.dispatch(CoreActions.addToLibrary(meta.json));
    }
    _tell('Downloading ${request.name}');
  }

  void _tell(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  void _selectVideoId(String videoId) {
    final video = ownState?.meta?.videoById(videoId);
    if (video != null) {
      _selectVideo(video, reveal: true);
    } else {
      _load(videoId);
    }
  }

  void _openGenre(ResourceRequest request) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'discover'),
        builder: (_) => DiscoverScreen(request: request),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final meta = state?.meta;
    if (state == null || meta == null) {
      final error = state?.metaError;
      return TvSafeArea(
        child: Scaffold(
          appBar: AppBar(),
          body: Center(
            child: error == null
                ? const CircularProgressIndicator()
                : Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Could not load this title: ${error.message}',
                      textAlign: TextAlign.center,
                    ),
                  ),
          ),
        ),
      );
    }
    return TvSafeArea(
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final isWide =
                constraints.maxWidth >= MetaDetailsScreen.wideBreakpoint;
            _isWide = isWide;
            final info = _infoSlivers(state, meta, isWide: isWide);
            final streams = _streamSlivers(state, meta);
            if (!isWide) {
              return CustomScrollView(
                controller: _narrowScroll,
                slivers: [...info, ...streams],
              );
            }
            final paneWidth = (constraints.maxWidth * 0.38).clamp(320.0, 480.0);
            final isTv = DeviceScope.isTv(context);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _tvGroup(isTv, CustomScrollView(slivers: info)),
                ),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: paneWidth,
                  child: _tvGroup(
                    isTv,
                    CustomScrollView(
                      slivers: [
                        SliverPadding(
                          padding: EdgeInsets.only(
                            top: MediaQuery.paddingOf(context).top + 8,
                          ),
                        ),
                        ...streams,
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// [child] as its own traversal group on a TV; [child] itself elsewhere.
  static Widget _tvGroup(bool isTv, Widget child) =>
      isTv ? FocusTraversalGroup(child: child) : child;

  /// Hero, facts and (for a series) the season selector and episode list.
  List<Widget> _infoSlivers(
    MetaDetailsState state,
    MetaItem meta, {
    required bool isWide,
  }) {
    final seasons = meta.seasons;
    final season =
        _season ??
        state.selectedVideo?.season ??
        state.initialVideo(preferred: widget.videoId)?.season ??
        (seasons.isEmpty ? null : seasons.first);
    final episodes = season == null ? meta.videos : meta.videosOfSeason(season);
    final now = DateTime.now().toUtc();
    return [
      SliverAppBar(
        pinned: true,
        expandedHeight: isWide ? 300 : 220,
        flexibleSpace: FlexibleSpaceBar(
          title: Text(meta.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          background: _Backdrop(url: meta.background, logo: meta.logo),
        ),
      ),
      SliverToBoxAdapter(
        child: _MetaHeader(
          meta: meta,
          isWide: isWide,
          isInLibrary: state.isInLibrary,
          downloads: _downloads?.ofMeta(widget.id) ?? const [],
          onGenre: _openGenre,
          onToggleLibrary: () => _toggleLibrary(state, meta),
        ),
      ),
      if (state.hasVideos) ...[
        if (seasons.length > 1 && season != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: _SeasonSelector(
                seasons: seasons,
                selected: season,
                isWide: isWide,
                onChanged: (season) => setState(() => _season = season),
              ),
            ),
          ),
        SliverList.builder(
          itemCount: episodes.length,
          itemBuilder: (context, index) {
            final video = episodes[index];
            return _EpisodeTile(
              video: video,
              isSelected: video.id == _selectedVideoId(state),
              isWatched: state.isWatched(video),
              isReleased: video.isReleased(now),
              download: _downloads?.forVideo(widget.id, video.id),
              onTap: () => _selectVideo(video, reveal: true),
              onLongPress: () => _toggleWatched(state, video),
            );
          },
        ),
      ],
      const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
    ];
  }

  /// The streams for the selected video, the meta addon's own first. The
  /// engine lists every addon it asked from the moment of the request (as
  /// `Loading` groups), so the header's small spinner is the only loading
  /// indicator needed once they are in; an empty list means no addon was
  /// asked. Between a tap and that first state there is nothing at all to
  /// list, and the section says so where the tap can see it.
  List<Widget> _streamSlivers(MetaDetailsState state, MetaItem meta) {
    final lastUsed = state.lastUsedStream;
    final groups = state.allStreamGroups;
    final noneYet =
        state.hasVideos && state.streamPath == null && groups.isEmpty;
    // A tapped episode whose streams have not arrived: everything below is
    // still the previous selection's, so show none of it.
    if (_isAwaitingStreams(state)) {
      return [
        SliverToBoxAdapter(
          child: _StreamsHeader(
            key: _streamsKey,
            state: state,
            video: meta.videoById(_awaitingVideoId!),
            isLoading: true,
          ),
        ),
        const SliverToBoxAdapter(
          child: ListTile(
            leading: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: Text(kLookingForStreams),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ];
    }
    // On a TV focus starts on the stream the user most likely wants: the
    // last used source, else the first playable one. Autofocus only takes
    // when nothing on the screen is focused yet, so streams arriving after
    // the user has moved on leave focus where it is.
    final isTv = DeviceScope.isTv(context);
    final autofocusAt = isTv && lastUsed == null
        ? _firstPlayable(groups)
        : null;
    final videoId = state.streamPath?.id ?? meta.id;
    final downloads = _downloadsClient == null
        ? null
        : _StreamDownloads(
            videoEntry: () => _videoDownload(videoId),
            isPending: (stream) =>
                _pending.contains(_streamKey(videoId, stream)),
            onDownload: (group, stream) =>
                _download(state, meta, group, stream),
          );
    return [
      SliverToBoxAdapter(
        child: _StreamsHeader(key: _streamsKey, state: state),
      ),
      if (noneYet)
        const SliverToBoxAdapter(
          child: ListTile(
            leading: Icon(Icons.touch_app_outlined),
            title: Text('Pick an episode to see its streams'),
          ),
        ),
      if (lastUsed != null)
        SliverToBoxAdapter(
          child: _StreamTile(
            stream: lastUsed.$2,
            highlighted: true,
            leadingIcon: Icons.history,
            titleOverride: 'Continue with last source',
            onTap: () => _play(state, lastUsed.$1, lastUsed.$2),
            autofocus: isTv,
            downloads: downloads?.forGroup(lastUsed.$1),
          ),
        ),
      for (final (index, group) in groups.indexed)
        _StreamGroupSliver(
          group: group,
          lastUsed: lastUsed?.$2,
          onPlay: (stream) => _play(state, group, stream),
          autofocusIndex: autofocusAt?.$1 == index ? autofocusAt!.$2 : null,
          downloads: downloads?.forGroup(group),
        ),
      const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
    ];
  }

  /// The (group, stream) indices of the first playable stream, if any.
  static (int, int)? _firstPlayable(List<StreamGroup> groups) {
    for (final (g, group) in groups.indexed) {
      for (final (s, stream) in group.streams.indexed) {
        if (stream.isPlayable) return (g, s);
      }
    }
    return null;
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.url, required this.logo});

  final String? url;
  final String? logo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = this.url;
    final logo = this.logo;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: scheme.surfaceContainerHighest),
        if (url != null)
          Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black26,
                Colors.black38,
                scheme.surface.withValues(alpha: 0.85),
              ],
            ),
          ),
        ),
        if (logo != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 64,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Image.network(
                logo,
                height: 56,
                fit: BoxFit.contain,
                alignment: Alignment.bottomLeft,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
      ],
    );
  }
}

class _MetaHeader extends StatelessWidget {
  const _MetaHeader({
    required this.meta,
    required this.isWide,
    required this.isInLibrary,
    required this.downloads,
    required this.onGenre,
    required this.onToggleLibrary,
  });

  final MetaItem meta;
  final bool isWide;

  /// `libraryItem.removed == false`: the bookmark is filled.
  final bool isInLibrary;

  /// Every download of this title, episodes included; empty for none.
  final List<DownloadView> downloads;
  final ValueChanged<ResourceRequest> onGenre;
  final VoidCallback onToggleLibrary;

  static const String addTooltip = 'Add to library';
  static const String removeTooltip = 'Remove from library';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final facts = [?meta.releaseInfo, ?meta.runtime, meta.type].join(' · ');
    final rating = meta.imdbRating;
    final genres = meta.genres;
    final posterWidth = isWide ? 130.0 : 90.0;
    final description = meta.description;

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(facts, style: theme.textTheme.labelLarge),
              ),
            ),
            IconButton(
              tooltip: isInLibrary ? removeTooltip : addTooltip,
              isSelected: isInLibrary,
              icon: const Icon(Icons.bookmark_border),
              selectedIcon: const Icon(Icons.bookmark),
              onPressed: onToggleLibrary,
            ),
          ],
        ),
        if (downloads.isNotEmpty) ...[
          const SizedBox(height: 6),
          DownloadSummary(downloads: downloads, metaId: meta.id),
        ],
        if (rating != null) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.star_rounded, size: 18, color: Colors.amber.shade400),
              const SizedBox(width: 4),
              Text(rating, style: theme.textTheme.labelLarge),
              const SizedBox(width: 4),
              Text(
                'IMDb',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
        if (genres.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: -8,
            children: [
              for (final genre in genres)
                ActionChip(
                  label: Text(genre.name),
                  visualDensity: VisualDensity.compact,
                  onPressed: switch (genre.discoverRequest) {
                    null => null,
                    final request => () => onGenre(request),
                  },
                ),
            ],
          ),
        ],
        if (isWide && description != null) ...[
          const SizedBox(height: 12),
          _ExpandableText(description),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: posterWidth,
                height: posterWidth * 1.5,
                child: PosterImage(url: meta.poster),
              ),
              const SizedBox(width: 16),
              Expanded(child: details),
            ],
          ),
          if (!isWide && description != null) ...[
            const SizedBox(height: 12),
            _ExpandableText(description),
          ],
        ],
      ),
    );
  }
}

/// Body text clamped to a few lines with a "More" toggle when it overflows.
class _ExpandableText extends StatefulWidget {
  const _ExpandableText(this.text);

  final String text;

  static const int collapsedLines = 4;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium;
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: _ExpandableText.collapsedLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: _expanded ? null : _ExpandableText.collapsedLines,
              overflow: _expanded ? null : TextOverflow.ellipsis,
            ),
            if (overflows)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? 'Less' : 'More'),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Season picker: a segmented button where there is room, a dropdown on
/// phones or for very long series. Season 0 is labelled "Specials".
class _SeasonSelector extends StatelessWidget {
  const _SeasonSelector({
    required this.seasons,
    required this.selected,
    required this.isWide,
    required this.onChanged,
  });

  final List<int> seasons;
  final int selected;
  final bool isWide;
  final ValueChanged<int> onChanged;

  static String label(int season) =>
      season == 0 ? 'Specials' : 'Season $season';

  @override
  Widget build(BuildContext context) {
    if (isWide && seasons.length <= 8) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [
            for (final season in seasons)
              ButtonSegment(value: season, label: Text(label(season))),
          ],
          selected: {selected},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
      );
    }
    if (DeviceScope.isTv(context)) {
      // The remote cannot pick from a DropdownMenu; the shared filter menu
      // reads "Season: 3" (or "Season: Specials") and opens a focusable list.
      // Full width, so that down from anything in the header above lands on
      // it: directional traversal prefers what overlaps horizontally.
      return SizedBox(
        width: double.infinity,
        child: FilterMenu<int>(
          label: 'Season',
          options: [
            for (final season in seasons)
              FilterOption(
                label: season == 0 ? label(season) : '$season',
                selected: season == selected,
                request: season,
              ),
          ],
          onSelect: onChanged,
        ),
      );
    }
    return DropdownMenu<int>(
      key: ValueKey(selected),
      initialSelection: selected,
      requestFocusOnTap: false,
      dropdownMenuEntries: [
        for (final season in seasons)
          DropdownMenuEntry(value: season, label: label(season)),
      ],
      onSelected: (season) {
        if (season != null) onChanged(season);
      },
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.video,
    required this.isSelected,
    required this.isWatched,
    required this.isReleased,
    required this.onTap,
    required this.onLongPress,
    this.download,
  });

  final VideoInfo video;
  final bool isSelected;
  final bool isWatched;
  final bool isReleased;

  /// This episode's download, whatever source it was taken from; null when
  /// it is not kept on the device.
  final DownloadView? download;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// `yyyy-MM-dd` of the air date, when known.
  static String? dateLabel(VideoInfo video) {
    final date = video.releasedAt;
    if (date == null) return null;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }

  /// The watched check (or the selection's play arrow), with the download
  /// badge in front of it when this episode is kept on the device.
  Widget? _trailing(ThemeData theme) {
    final download = this.download;
    final state = isWatched
        ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
        : isSelected
        ? const Icon(Icons.play_arrow)
        : null;
    if (download == null) return state;
    final badge = DownloadBadge(download: download);
    if (state == null) return badge;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [badge, const SizedBox(width: 8), state],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = dateLabel(video);
    final episode = video.episode;
    final title = video.title.isEmpty && episode != null
        ? 'Episode $episode'
        : video.title;
    final tile = ListTile(
      selected: isSelected,
      enabled: isReleased,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: _EpisodeThumbnail(video: video),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: date == null && isReleased
          ? null
          : Text(
              [?date, if (!isReleased) 'Upcoming'].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
      trailing: _trailing(theme),
    );
    if (!DeviceScope.isTv(context)) return tile;
    return RemotePress(onTap: onTap, onLongPress: onLongPress, child: tile);
  }
}

class _EpisodeThumbnail extends StatelessWidget {
  const _EpisodeThumbnail({required this.video});

  final VideoInfo video;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnail = video.thumbnail;
    final episode = video.episode;
    return SizedBox(
      width: 96,
      height: 54,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
            if (thumbnail != null)
              Image.network(
                thumbnail,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            if (episode != null)
              Positioned(
                left: 4,
                bottom: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    child: Text(
                      'E$episode',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// What the stream section says between a tap on an episode and the
/// engine's answer.
const String kLookingForStreams = 'Looking for streams…';

class _StreamsHeader extends StatelessWidget {
  const _StreamsHeader({
    super.key,
    required this.state,
    this.video,
    this.isLoading = false,
  });

  final MetaDetailsState state;

  /// The episode the section is about; null takes the state's selection.
  /// A tap that has not been answered yet names the tapped episode here,
  /// which the state does not know about.
  final VideoInfo? video;

  /// Spins even when no addon group is loading yet (a tap whose `Load` has
  /// not come back).
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final video = this.video ?? state.selectedVideo;
    final meta = state.meta;
    final subtitle = video != null && meta != null && video.id != meta.id
        ? [
            if (video.seasonEpisodeLabel.isNotEmpty) video.seasonEpisodeLabel,
            if (video.title.isNotEmpty) video.title,
          ].join(' · ')
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Streams',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                if (subtitle != null)
                  Text(subtitle, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (isLoading || state.isLoadingStreams)
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

/// Asks before a download replaces a finished one of the same video taken
/// from another release. Popping `true` goes ahead; the file that is on
/// the device is deleted by the Rust side as the new pin is taken, and
/// there is no undo, which is why it is named here.
class _ReplaceDialog extends StatelessWidget {
  const _ReplaceDialog({required this.replaced});

  final DownloadView replaced;

  static const String replaceLabel = 'Replace it';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Replace ${replaced.name}?'),
    content: Text(
      'It is already downloaded from another source. Downloading this '
      'stream deletes those ${replaced.sizeLabel} and starts again from '
      'nothing.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text(replaceLabel),
      ),
    ],
  );
}

/// What a stream tile knows about offline downloads: the entry for its
/// stream if the registry has one, whether a pin for it is in flight, and
/// how to start one. Bound to the addon group the tile sits in, because a
/// pin records the request its stream came from.
final class _StreamDownloads {
  const _StreamDownloads({
    required this.videoEntry,
    required this.isPending,
    required this.onDownload,
    this.group,
  });

  /// The download of the video these tiles belong to, from any source.
  final DownloadView? Function() videoEntry;
  final bool Function(StreamInfo stream) isPending;
  final void Function(StreamGroup group, StreamInfo stream) onDownload;

  /// The addon group; null until [forGroup] binds one, which is when a tile
  /// can offer to download at all.
  final StreamGroup? group;

  _StreamDownloads forGroup(StreamGroup group) => _StreamDownloads(
    videoEntry: videoEntry,
    isPending: isPending,
    onDownload: onDownload,
    group: group,
  );

  /// The download taken from [stream] itself, if there is one.
  DownloadView? entryOf(StreamInfo stream) {
    final entry = videoEntry();
    return entry != null && entry.stream.isSameSource(stream) ? entry : null;
  }

  /// The download this stream would replace: the same video kept from
  /// another release, which is a different file. Pinning this one drops
  /// that pin and the server deletes its bytes, so the tile has to say so
  /// instead of looking like a first download.
  DownloadView? replacedBy(StreamInfo stream) {
    final entry = videoEntry();
    return entry != null && !entry.stream.isSameSource(stream) ? entry : null;
  }

  /// Starts the download of [stream]; null when the server has nothing to
  /// pin (only a torrent stream is a file it keeps) or one is already on
  /// its way.
  VoidCallback? starter(StreamInfo stream) {
    final group = this.group;
    if (group == null || stream.kind != StreamKind.torrent) return null;
    if (isPending(stream)) return null;
    return () => onDownload(group, stream);
  }
}

class _StreamGroupSliver extends StatelessWidget {
  const _StreamGroupSliver({
    required this.group,
    required this.lastUsed,
    required this.onPlay,
    this.autofocusIndex,
    this.downloads,
  });

  final StreamGroup group;

  /// The stream pinned as "Continue with last source", highlighted here too.
  final StreamInfo? lastUsed;
  final ValueChanged<StreamInfo> onPlay;

  /// The stream (by index) where TV focus starts; null for none here.
  final int? autofocusIndex;

  /// The downloads, when there is a client above this screen.
  final _StreamDownloads? downloads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = group.error;
    final streams = group.streams;
    final label = group.isFromMeta
        ? 'From ${group.addonLabel}'
        : group.addonLabel;
    final settledEmpty =
        streams.isEmpty &&
        (error?.isEmptyContent == true ||
            (error == null && group.content != null));
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (error != null && !error.isEmptyContent)
          SliverToBoxAdapter(
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.cloud_off_outlined),
              title: Text(error.message),
            ),
          )
        else if (settledEmpty)
          const SliverToBoxAdapter(
            child: ListTile(dense: true, title: Text('No streams')),
          ),
        SliverList.builder(
          itemCount: streams.length,
          itemBuilder: (context, index) {
            final stream = streams[index];
            final lastUsed = this.lastUsed;
            return _StreamTile(
              stream: stream,
              highlighted: lastUsed != null && stream.isSameSource(lastUsed),
              onTap: stream.isPlayable ? () => onPlay(stream) : null,
              autofocus: index == autofocusIndex,
              downloads: downloads,
            );
          },
        ),
      ],
    );
  }
}

/// One stream: its name, what is left of the description once the quality
/// hints are pulled out into chips, a download affordance for a torrent,
/// and a play affordance (or the kind of source when the player cannot
/// open it).
class _StreamTile extends StatelessWidget {
  const _StreamTile({
    required this.stream,
    required this.onTap,
    this.highlighted = false,
    this.leadingIcon,
    this.titleOverride,
    this.autofocus = false,
    this.downloads,
  });

  final StreamInfo stream;
  final VoidCallback? onTap;
  final bool highlighted;
  final IconData? leadingIcon;
  final String? titleOverride;

  /// Where TV focus starts on the screen (see [MetaDetailsScreen]).
  final bool autofocus;

  /// The offline downloads, when there is a client above this screen.
  final _StreamDownloads? downloads;

  @override
  Widget build(BuildContext context) {
    final hints = StreamHints.of(stream);
    final title = titleOverride ?? stream.title;
    // A name that is nothing but the hint ("1080p") needs no chip for it.
    final chips = [
      for (final chip in hints.chips)
        if (chip.toLowerCase() != stream.title.toLowerCase()) chip,
    ];
    final description = titleOverride != null
        ? stream.title
        : stream.name == null
        ? null
        : hints.strip(stream.description);
    final isTv = DeviceScope.isTv(context);
    final tile = ListTile(
      enabled: onTap != null,
      selected: highlighted,
      autofocus: autofocus,
      leading: Icon(leadingIcon ?? _iconFor(stream.kind)),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: description != null && chips.isNotEmpty,
      subtitle: description == null && chips.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (description != null)
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (chips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [for (final chip in chips) _HintChip(chip)],
                    ),
                  ),
              ],
            ),
      trailing: _trailing(context),
      onTap: onTap,
    );
    final filename = hints.filename;
    final withTooltip = filename == null
        ? tile
        : Tooltip(message: filename, child: tile);
    return isTv ? RemotePress(onTap: onTap, child: withTooltip) : withTooltip;
  }

  /// The download affordance (when there is one) beside the play one.
  Widget _trailing(BuildContext context) {
    final theme = Theme.of(context);
    final play = onTap != null
        ? const Icon(Icons.play_arrow)
        : Text(stream.kind.label, style: theme.textTheme.labelSmall);
    final download = _downloadAffordance(context);
    if (download == null) return play;
    return Row(mainAxisSize: MainAxisSize.min, children: [download, play]);
  }

  /// What the download side of the tile shows: a button to start one, a
  /// ring while it arrives, a check once it is on the device, and the
  /// error as a button that pins again. Nothing at all for a stream the
  /// server cannot keep (anything but a torrent) or with no client above.
  Widget? _downloadAffordance(BuildContext context) {
    final downloads = this.downloads;
    if (downloads == null) return null;
    if (downloads.isPending(stream)) {
      return const _DownloadIndicator(
        tooltip: kDownloadStartingTooltip,
        progress: null,
      );
    }
    final entry = downloads.entryOf(stream);
    final start = downloads.starter(stream);
    if (entry == null) {
      if (start == null) return null;
      // The same video kept from another release: this button does not add
      // a download, it swaps one for another and the old file goes. Say
      // that here, where the press happens -- the summary in the header is
      // scrolled away by the time a stream tile is reached on a phone.
      final replaced = downloads.replacedBy(stream);
      return IconButton(
        tooltip: replaced == null ? kDownloadTooltip : kDownloadReplaceTooltip,
        icon: Icon(
          replaced == null ? Icons.download_outlined : Icons.swap_horiz,
        ),
        onPressed: start,
      );
    }
    return switch (entry.state) {
      DownloadState.complete => IconTheme.merge(
        data: IconThemeData(color: Theme.of(context).colorScheme.primary),
        child: const _DownloadIndicator(
          tooltip: kDownloadedTooltip,
          icon: Icons.download_done,
        ),
      ),
      DownloadState.error => IconButton(
        tooltip: kDownloadRetryTooltip,
        icon: const Icon(Icons.error_outline),
        onPressed: start,
      ),
      // A ring at 0 rather than a spinner: a queued download whose length
      // is not known yet is still a fraction of nothing, and an
      // indeterminate spinner would say "working" about a file nobody is
      // sending yet.
      _ => _DownloadIndicator(
        tooltip: downloadStateLabel(entry),
        progress: entry.progress ?? 0,
      ),
    };
  }

  static IconData _iconFor(StreamKind kind) => switch (kind) {
    StreamKind.torrent || StreamKind.magnet => Icons.cloud_download_outlined,
    StreamKind.url => Icons.link,
    StreamKind.youtube => Icons.smart_display_outlined,
    StreamKind.external => Icons.open_in_new,
    StreamKind.playerFrame => Icons.web,
    StreamKind.archive => Icons.folder_zip_outlined,
    StreamKind.unknown => Icons.help_outline,
  };
}

/// The non-pressable half of the download affordance: a progress ring (or
/// a spinner while there is no fraction to show) or a finished icon, padded
/// to the size of the [IconButton] it stands in for so the tile does not
/// jump when the state changes.
class _DownloadIndicator extends StatelessWidget {
  const _DownloadIndicator({required this.tooltip, this.progress, this.icon});

  final String tooltip;

  /// `0..1` of the file; null spins.
  final double? progress;

  /// Shown instead of a ring.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: SizedBox.square(
          dimension: 20,
          child: icon != null
              ? Icon(icon, size: 20)
              : CircularProgressIndicator(strokeWidth: 2, value: progress),
        ),
      ),
    );
  }
}

class _HintChip extends StatelessWidget {
  const _HintChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}
