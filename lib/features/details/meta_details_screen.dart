import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/tv_density.dart';
import '../../widgets/download_badge.dart';
import '../../widgets/filter_controls.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/poster_tile.dart';
import '../../widgets/remote_press.dart';
import '../../widgets/shared_field_screen.dart';
import '../addons/addons_screen.dart';
import '../addons/failed_addons.dart';
import '../discover/discover_screen.dart';
import '../downloads/download_labels.dart';
import '../downloads/downloads_controller.dart';
import '../downloads/downloads_screen.dart';
import '../downloads/offline_play.dart';
import '../downloads/remove_download_dialog.dart';
import '../player/player_screen.dart';
import 'stream_facts.dart';
import 'stream_sources.dart';
import 'tv_backdrop.dart';

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
/// The sources list has two layouts, and which one it is in is a global
/// preference ([AppPrefs.streamsSectioned]) rather than a per-title one:
/// the section header carries the toggle, the choice follows the user to
/// the next title, and it is read from the Rust side's preferences file at
/// start-up so the first list is already the one they left. **Sectioned**
/// -- every addon's answers together, cut by **resolution**: one
/// collapsible section per rung, highest first, the streams nothing could
/// be read from in a section of their own at the bottom that says so
/// rather than guessing -- is the default, so the layout the sources list
/// was built for is the one a fresh install actually sees. Inside a
/// section the order is [StreamOrder], the same for every section, and
/// each row names the addon it came from since it has no addon heading to
/// sit under any more.
///
/// The other layout is **grouped**: a section per addon, in profile order,
/// each addon's own ranking intact -- what the engine hands over, and what
/// this list looked like before the sectioned layout existed.
///
/// Every resolution section starts *collapsed*, on every title, until the
/// viewer opens one: a *closed* header still says how many streams it
/// holds and the best swarm among them ([StreamSection.summary]) -- an
/// empty-looking 2160p and a healthy one are different answers -- so a
/// compact list of what is available is the first thing shown, and opening
/// one is a choice rather than something already made for the viewer.
/// Which sections are open is [AppPrefs.openStreamSections]: a *global*
/// preference like the layout itself, not a per-screen one, so a section
/// opened on one title is open on the next, and again after a restart. A
/// resolution the current title does not offer is simply not shown open --
/// it is never swapped for some other section the viewer did not ask for.
///
/// Everything around the streams is the same in both layouts: the
/// last-used shortcut, the addons that had nothing, the ones that failed,
/// and the notice when nobody had anything.
///
/// One release is one row. Two addons offering the same torrent -- and one
/// addon offering it twice -- are the same *content*, identified by
/// [StreamInfo.sourceKey] (an info hash and a file index, or a direct URL:
/// the identity a pin is already keyed by), never by what a row looks like.
/// Two different releases with the same resolution and size are two
/// sources and stay two rows. The sectioned list collapses them after the
/// sort and across the whole list -- so what survives is the best-ranked
/// instance, and a source two addons described differently cannot show up
/// in two sections -- and says "Also from ..." when another *addon* had
/// it, silently when one addon merely repeated itself. The grouped list
/// keeps a copy in each addon's own group -- the groups are what that
/// layout is for -- marked the same way, and collapses only an addon's
/// repeats of its own. Either way the surviving row carries
/// the *union* of every listing's trackers ([StreamSourceIndex]), so the
/// stream handed to playback, to a download and to the stats poll asks
/// every tracker anybody named.
///
/// An addon that answers a stream request with an error is not listed as an
/// empty group but collected below the streams that worked, named from the
/// profile (`ctx`) rather than by the host in its manifest URL, with the two
/// things worth doing about it: opening its details, whose manifest fetch is
/// the reachability test, and uninstalling it. Several at once collapse into
/// one summary row, so a profile full of dead mirrors does not bury the
/// streams that still play.
///
/// An addon that answered with *nothing* is not listed either: most stream
/// addons have nothing for most episodes, and a labelled "No streams"
/// section each pushed the real streams off the screen. They become one
/// quiet line below the streams saying how many there were, which expands
/// to name them. The three states stay apart: an addon still being waited
/// on keeps its label and a spinner, one that answered with nothing is in
/// that line, and one that failed has its own section.
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

  /// `ctx`, for the installed addons: a stream group that failed carries
  /// only the manifest URL it was asked at, and the profile is what turns
  /// that into an addon with a name that can be uninstalled.
  CoreFieldNotifier? _ctx;

  /// The downloads, when the app put a client above this screen (it always
  /// does; a test that does not care about downloads need not). Null leaves
  /// the download affordances off the tiles entirely.
  DownloadsClient? _downloadsClient;
  DownloadsController? _downloads;

  /// The app's preferences, for the sources list's layout. From the
  /// [PrefsScope] the app puts above every screen; a screen mounted
  /// without one (a widget test that does not care where the choice goes)
  /// gets [_ownPrefs] instead, which persists nothing.
  AppPrefs? _prefs;
  AppPrefs? _ownPrefs;

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
      _ctx?.dispose();
      _client = client;
      _details = CoreFieldNotifier(client, CoreField.metaDetails)
        ..addListener(onFieldChanged);
      _ctx = CoreFieldNotifier(client, CoreField.ctx)
        ..addListener(_onProfileChanged);
      _load(widget.videoId);
    }
    // Reading the scope here is what subscribes to it: an `InheritedNotifier`
    // rebuilds its dependents when the value changes, so a layout chosen on
    // another screen is already in place when this one comes back.
    final prefs =
        PrefsScope.maybeOf(context) ?? (_ownPrefs ??= AppPrefs.inMemory());
    if (_prefs != prefs) {
      _prefs?.removeListener(_onPrefsChanged);
      _prefs = prefs..addListener(_onPrefsChanged);
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

  void _onProfileChanged() {
    if (mounted) setState(() {});
  }

  void _onPrefsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    releaseField();
    _narrowScroll.dispose();
    _details?.dispose();
    _ctx
      ?..removeListener(_onProfileChanged)
      ..dispose();
    _downloads
      ?..removeListener(_onDownloadsChanged)
      ..dispose();
    _prefs?.removeListener(_onPrefsChanged);
    _ownPrefs?.dispose();
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

  /// The profile behind `ctx`; null until its first pull comes back.
  ProfileState? get _profile {
    final ctx = _ctx?.value;
    return ctx == null ? null : ProfileState.fromCtx(ctx);
  }

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

  /// Drops the download of [entry] once the user has said what should
  /// happen to the file -- the Downloads list's own question, asked here so
  /// the tile that started a download is the tile that undoes it.
  ///
  /// The dialog is modal, so it is the guard against a second press while
  /// it stands, and a dismissed one removes nothing.
  Future<void> _deleteDownload(DownloadView entry) async {
    final client = _downloadsClient;
    final downloads = _downloads;
    if (client == null || downloads == null) return;
    final deleteFiles = await askToRemoveDownload(context, entry);
    if (deleteFiles == null || !mounted) return;
    DownloadRemoveResult? result;
    try {
      result = await client.remove(entry.key, deleteFiles: deleteFiles);
    } catch (_) {
      if (mounted) _tell('This download could not be removed.');
    }
    // The tiles read the registry, so they only stop saying the title is
    // kept once the fresh listing is in.
    await downloads.refresh();
    if (result == null || !mounted) return;
    _tell(downloadRemovedMessage(result, entry));
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

  /// Everything kept on this device. Reached from here as well as from the
  /// Library and the Settings, because what is downloaded is most worth
  /// looking at from the title the downloads were taken from: the tile that
  /// keeps an episode is two taps from the list that holds the rest.
  void _openDownloads() {
    Navigator.of(context).push(DownloadsScreen.route());
  }

  /// The Addons screen, where a stream addon is installed by manifest URL.
  void _openAddons() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'addons'),
        builder: (_) => const AddonsScreen(),
      ),
    );
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
    final isTv = DeviceScope.isTv(context);
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= MetaDetailsScreen.wideBreakpoint;
        _isWide = isWide;
        final info = _infoSlivers(state, meta, isWide: isWide, isTv: isTv);
        final streams = _streamSlivers(state, meta);
        if (!isWide) {
          return CustomScrollView(
            controller: _narrowScroll,
            slivers: [...info, ...streams],
          );
        }
        final paneWidth = (constraints.maxWidth * 0.38).clamp(320.0, 480.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _tvGroup(isTv, CustomScrollView(slivers: info))),
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
    );
    if (!isTv) return TvSafeArea(child: Scaffold(body: body));
    // On a television the artwork fills the panel and the content keeps
    // clear of the overscan band inside it, which is why this is a plain
    // `SafeArea` rather than [TvSafeArea]: that one paints the band with
    // the scaffold's own colour, which would cover the backdrop with a
    // strip of ground at every edge.
    return Scaffold(
      body: TvBackdrop(
        background: meta.background,
        poster: meta.poster,
        child: SafeArea(child: body),
      ),
    );
  }

  /// [child] as its own traversal group on a TV; [child] itself elsewhere.
  static Widget _tvGroup(bool isTv, Widget child) =>
      isTv ? FocusTraversalGroup(child: child) : child;

  /// Hero, facts and (for a series) the season selector and episode list.
  ///
  /// On a television the hero is gone: [TvBackdrop] is already drawing the
  /// artwork across the whole panel, so a second copy of it inside a
  /// collapsing app bar would be the same picture twice. What is left of
  /// the bar is the way back and the way to the downloads list, floating
  /// over the backdrop.
  List<Widget> _infoSlivers(
    MetaDetailsState state,
    MetaItem meta, {
    required bool isWide,
    required bool isTv,
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
        pinned: !isTv,
        expandedHeight: isTv ? null : (isWide ? 300 : 220),
        backgroundColor: isTv ? Colors.transparent : null,
        scrolledUnderElevation: isTv ? 0 : null,
        actions: [
          if (_downloadsClient != null)
            IconButton(
              tooltip: kDownloadsScreenTooltip,
              onPressed: _openDownloads,
              icon: const Icon(Icons.download_outlined),
            ),
        ],
        flexibleSpace: isTv
            ? null
            : FlexibleSpaceBar(
                title: Text(
                  meta.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
              onDeleteDownload: _deleteDownload,
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
    final isSectioned = _prefs?.streamsSectioned ?? true;
    final order = _prefs?.streamsOrder ?? StreamOrder.peersPerSize;
    final lastUsed = state.lastUsedStream;
    final groups = state.allStreamGroups;
    final noneYet =
        state.hasVideos && state.streamPath == null && groups.isEmpty;
    // Every addon that was asked has answered and none of them offered
    // anything the player can open. On a fresh profile that is the normal
    // answer rather than a fault, so it is explained rather than left as
    // an empty list under a heading.
    final foundNothing =
        state.streamPath != null &&
        groups.isNotEmpty &&
        !state.isLoadingStreams &&
        lastUsed == null &&
        state.playableStreams.isEmpty;
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
            sectioned: isSectioned,
            onSectionedChanged: _setStreamsSectioned,
            order: order,
            onOrderChanged: _setStreamsOrder,
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
    // An addon that answered with an error has nothing to list, so it is
    // pulled out of the run of groups and collected below the streams
    // instead: several dead addons at once are one row there, not a wall
    // of them above the streams that do work.
    final profile = _profile;
    final answered = [
      for (final g in groups)
        if (!_hasFailed(g)) g,
    ];
    // An addon that answered with nothing is not a section of its own
    // either: most stream addons have nothing for most episodes, and a
    // label plus "No streams" each was most of what the list showed.
    final listed = [
      for (final g in answered)
        if (!_answeredEmpty(g)) g,
    ];
    final empties = [
      for (final g in answered)
        if (_answeredEmpty(g)) g,
    ];
    final failures = [
      for (final group in groups)
        if (_hasFailed(group))
          AddonFailure(
            transportUrl: group.request.base,
            addon: profile?.installedAddon(group.request.base),
            fallbackName: group.addonLabel,
            message: group.error?.message ?? '',
          ),
    ];
    // What the addons agree is one source, and what each of them said its
    // trackers were. Both layouts collapse on it, and the row that
    // survives plays and downloads with the union of those trackers.
    final sources = StreamSourceIndex.of([
      for (final group in listed)
        for (final stream in group.streams)
          (addon: _addonNameOf(profile, group), stream: stream),
    ]);
    // The sectioned layout: every listed addon's streams together, put in
    // the chosen order ([StreamOrder], the same one for every section) and
    // then split into a collapsible section per resolution. Each row names
    // the addon it came from, since it has no heading to sit under any
    // more. Built only for the layout that shows it -- parsing every
    // stream costs a handful of regexes each.
    //
    // Sorted, then collapsed, then sectioned, in that order and for a
    // reason each: the instance of a duplicate that survives is the
    // best-ranked one rather than whichever addon was asked first, the
    // collapse is across the whole list so a source two addons described
    // differently cannot appear in two sections, and sectioning keeps the
    // order it is handed, so each section is already sorted.
    final sections = isSectioned
        ? sectionsByResolution(
            _collapse(
              sortedByStreamOrder(
                [
                  for (final group in listed)
                    for (final stream in group.streams)
                      (
                        group: group,
                        stream: stream,
                        facts: StreamFacts.of(
                          stream,
                          addonName: _addonNameOf(profile, group),
                        ),
                        alsoFrom: const <String>[],
                      ),
                ],
                (row) => row.facts!,
                order,
              ),
              sources,
              (row) => row.facts?.addonName ?? '',
            ),
            (row) => row.facts!,
          )
        : const <StreamSection<_SourceRow>>[];
    final openSections = _visibleOpenSections(sections);
    // The grouped layout: each addon's own ranking, with the addon's own
    // repeats collapsed. A source two addons both offered stays in both
    // groups -- the groups are the point of this layout -- and each row
    // says the other addon has it too.
    final grouped = isSectioned
        ? const <(StreamGroup, List<_SourceRow>)>[]
        : [
            for (final group in listed)
              (
                group,
                _collapse(
                  [
                    for (final stream in group.streams)
                      (
                        group: group,
                        stream: stream,
                        facts: null,
                        alsoFrom: const <String>[],
                      ),
                  ],
                  sources,
                  (_) => _addonNameOf(profile, group),
                ),
              ),
          ];
    final autofocusAt = isTv && lastUsed == null
        ? _firstPlayable(grouped)
        : null;
    // The first playable stream of an *open* section: a collapsed one has
    // nothing on screen to focus.
    final sectionAutofocusAt = isTv && lastUsed == null && isSectioned
        ? _firstPlayableSection(sections, openSections)
        : null;
    // Every section starts collapsed, so most of the time there is no
    // stream row to land on: focus the first section's own header instead,
    // which a remote can already open with select.
    final headerAutofocusAt =
        isTv &&
            lastUsed == null &&
            isSectioned &&
            sectionAutofocusAt == null &&
            sections.isNotEmpty
        ? 0
        : null;
    // The shortcut is the same source as one of the rows below, so it is
    // handed the same merged trackers; nothing else about it changes.
    final lastUsedStream = lastUsed == null
        ? null
        : sources.merged(lastUsed.$2);
    final videoId = state.streamPath?.id ?? meta.id;
    final downloads = _downloadsClient == null
        ? null
        : _StreamDownloads(
            videoEntry: () => _videoDownload(videoId),
            isPending: (stream) =>
                _pending.contains(_streamKey(videoId, stream)),
            onDownload: (group, stream) =>
                _download(state, meta, group, stream),
            onDelete: _deleteDownload,
          );
    return [
      SliverToBoxAdapter(
        child: _StreamsHeader(
          key: _streamsKey,
          state: state,
          sectioned: isSectioned,
          onSectionedChanged: _setStreamsSectioned,
          order: order,
          onOrderChanged: _setStreamsOrder,
        ),
      ),
      if (foundNothing)
        SliverToBoxAdapter(
          child: _NoStreamsNotice(
            isEpisode: state.hasVideos,
            onAddons: _openAddons,
          ),
        ),
      if (noneYet)
        const SliverToBoxAdapter(
          child: ListTile(
            leading: Icon(Icons.touch_app_outlined),
            title: Text('Pick an episode to see its streams'),
          ),
        ),
      if (lastUsedStream != null)
        SliverToBoxAdapter(
          child: _StreamTile(
            stream: lastUsedStream,
            highlighted: true,
            leadingIcon: Icons.history,
            titleOverride: 'Continue with last source',
            onTap: () => _play(state, lastUsed!.$1, lastUsedStream),
            autofocus: isTv,
            downloads: downloads?.forGroup(lastUsed!.$1),
          ),
        ),
      if (isSectioned)
        for (final (index, section) in sections.indexed)
          _ResolutionSectionSliver(
            section: section,
            expanded: openSections.contains(section.resolution),
            onExpand: () => _toggleSection(section.resolution),
            lastUsed: lastUsed?.$2,
            onPlay: (row) => _play(state, row.group, row.stream),
            autofocusIndex: sectionAutofocusAt?.$1 == index
                ? sectionAutofocusAt!.$2
                : null,
            headerAutofocus: headerAutofocusAt == index,
            downloads: downloads,
          )
      else ...[
        for (final (index, entry) in grouped.indexed)
          _StreamGroupSliver(
            group: entry.$1,
            rows: entry.$2,
            lastUsed: lastUsed?.$2,
            onPlay: (stream) => _play(state, entry.$1, stream),
            autofocusIndex: autofocusAt?.$1 == index ? autofocusAt!.$2 : null,
            downloads: downloads?.forGroup(entry.$1),
          ),
      ],
      if (empties.isNotEmpty)
        SliverToBoxAdapter(
          child: _EmptyAddonsSummary(
            names: [
              for (final group in empties)
                profile?.installedAddon(group.request.base)?.manifest.name ??
                    group.addonLabel,
            ],
            isEpisode: state.hasVideos,
          ),
        ),
      if (failures.isNotEmpty)
        SliverToBoxAdapter(
          child: FailedAddonsSection(
            failures: failures,
            summaryLabel: FailedAddonsSection.addonsLabel(failures.length),
            locked: profile?.addonsLocked ?? false,
            onCheck: (failure) =>
                openAddonDetails(context, failure.transportUrl),
            onUninstall: (failure) =>
                confirmAndUninstallAddon(context, _client, failure.addon!),
          ),
        ),
      const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
    ];
  }

  /// Puts the sources list in one layout or the other, for everything the
  /// app shows from now on: the preference is global, not this title's.
  void _setStreamsSectioned(bool value) => _prefs?.setStreamsSectioned(value);

  /// Puts every resolution section in one order or another, again for
  /// everything the app shows from now on rather than for this title.
  void _setStreamsOrder(StreamOrder value) => _prefs?.setStreamsOrder(value);

  /// The label [AppPrefs.openStreamSections] stores one section under: a
  /// resolution's own [StreamResolution.label], or `'unknown'` for the
  /// section nothing could be read a resolution from -- the same word
  /// [streamSectionKey] uses for that section's widget key.
  static String _sectionStorageLabel(StreamResolution? resolution) =>
      resolution?.label ?? 'unknown';

  /// Every resolution the viewer has ever opened, anywhere, parsed back
  /// from [AppPrefs.openStreamSections]. A label this build does not
  /// recognise -- a newer build's rung, a stray value -- is dropped rather
  /// than guessed at, the same as an unparseable [StreamOrder]. Empty both
  /// when nothing has ever been chosen and when the viewer collapsed
  /// everything on purpose; [AppPrefs.openStreamSections] is what keeps
  /// those two apart in storage; this screen draws them identically.
  Set<StreamResolution?> _rememberedOpenSections() {
    final result = <StreamResolution?>{};
    for (final label in _prefs?.openStreamSections ?? const <String>{}) {
      if (label == 'unknown') {
        result.add(null);
        continue;
      }
      for (final resolution in StreamResolution.values) {
        if (resolution.label == label) {
          result.add(resolution);
          break;
        }
      }
    }
    return result;
  }

  /// Which of [sections] are drawn open: the remembered resolutions this
  /// title actually offers, and nothing else. A remembered resolution the
  /// title does not have is simply not shown open -- never substituted
  /// with some other section the viewer did not ask for.
  Set<StreamResolution?> _visibleOpenSections(
    List<StreamSection<_SourceRow>> sections,
  ) {
    final chosen = _rememberedOpenSections();
    return {
      for (final section in sections)
        if (chosen.contains(section.resolution)) section.resolution,
    };
  }

  /// Opens or closes one section, on the *full* remembered set (every
  /// resolution ever opened on any title), not just what this title shows
  /// open: otherwise closing a section here could silently drop a resolution
  /// another title still remembers, one this title never offered in the
  /// first place.
  void _toggleSection(StreamResolution? resolution) {
    final full = _rememberedOpenSections();
    final next = {
      for (final section in full)
        if (section != resolution) section,
      if (!full.contains(resolution)) resolution,
    };
    _prefs?.setOpenStreamSections({
      for (final section in next) _sectionStorageLabel(section),
    });
  }

  /// What an addon is called in a list that has lost its headings: the
  /// installed addon's own name, else the host its manifest URL names --
  /// the same fallback the failed-addon rows use.
  static String _addonNameOf(ProfileState? profile, StreamGroup group) =>
      profile?.installedAddon(group.request.base)?.manifest.name ??
      group.addonLabel;

  /// Whether the addon answered with something other than streams: an
  /// error that is not the ordinary "this addon has nothing for this
  /// video" ([LoadableError.isEmptyContent]).
  static bool _hasFailed(StreamGroup group) {
    final error = group.error;
    return error != null && !error.isEmptyContent;
  }

  /// Whether the addon has answered and had nothing: no streams, nothing
  /// still on its way, and no failure (which [_hasFailed] takes first).
  /// The engine's own "this addon has nothing for this video"
  /// ([LoadableError.isEmptyContent]) is one of these, not a failure.
  static bool _answeredEmpty(StreamGroup group) =>
      group.streams.isEmpty && !group.isLoading;

  /// [rows] with every source listed once: the first row naming a source
  /// stays and the later ones go, which after a sort is the best-ranked
  /// instance. What survives carries the union of every listing's trackers
  /// and the other addons that offered it, so the collapse hides an
  /// option from nobody -- and when one addon simply repeated itself there
  /// is no other addon to name and the row says nothing.
  ///
  /// A stream with no source key at all (an unknown variant) is never
  /// folded into anything; it is its own row, however many there are.
  static List<_SourceRow> _collapse(
    List<_SourceRow> rows,
    StreamSourceIndex sources,
    String Function(_SourceRow row) addonOf,
  ) {
    final seen = <String>{};
    return [
      for (final row in rows)
        if (row.stream.sourceKey == null || seen.add(row.stream.sourceKey!))
          (
            group: row.group,
            stream: sources.merged(row.stream),
            facts: row.facts,
            alsoFrom: sources.alsoFrom(addonOf(row), row.stream),
          ),
    ];
  }

  /// The (section, row) indices of the first playable stream in an open
  /// section, if any: a collapsed section is not on screen to be focused.
  static (int, int)? _firstPlayableSection(
    List<StreamSection<_SourceRow>> sections,
    Set<StreamResolution?> open,
  ) {
    for (final (s, section) in sections.indexed) {
      if (!open.contains(section.resolution)) continue;
      for (final (r, row) in section.rows.indexed) {
        if (row.stream.isPlayable) return (s, r);
      }
    }
    return null;
  }

  /// The (group, row) indices of the first playable stream, if any.
  static (int, int)? _firstPlayable(
    List<(StreamGroup, List<_SourceRow>)> groups,
  ) {
    for (final (g, entry) in groups.indexed) {
      for (final (s, row) in entry.$2.indexed) {
        if (row.stream.isPlayable) return (g, s);
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

/// The seasons of a series, as one horizontally scrolling row of pills with
/// the current one filled. Season 0 is `Specials`; every other pill is the
/// bare number, beside a "Season" label so that a lone `3` says what it is.
///
/// One shape on every device, because a season is a single short token and
/// a row of them is readable at a glance. The three controls this replaced
/// -- segments where there was room, a menu on a television, a dropdown
/// everywhere else -- all spent a press on opening and another on choosing,
/// and the two that opened a list opened it as a very narrow, very tall
/// column of digits, which on a remote is a long vertical crawl.
///
/// Two things it has to do that a plain row would not:
///
/// - **Every pill is built at once**: a [Row] inside a
///   [SingleChildScrollView], never a lazy [ListView]. Flutter's
///   directional traversal only considers widgets that have been built, so
///   a lazily built row silently stops the D-pad at the last realised pill
///   however many seasons the series has.
/// - **The pills fill the row** whenever they fit, an even share of the
///   width each. Directional focus prefers what overlaps it horizontally,
///   so a short row packed at the left is stepped over by anything coming
///   down the right-hand side of the header.
/// - **The selected pill is scrolled into view** when the season changes or
///   the row is built for another title, so season 12 does not open with
///   the row parked at 1. Only the row moves: [ScrollPosition.ensureVisible]
///   on its own position, rather than [Scrollable.ensureVisible], which
///   would drag the page's vertical scroll along with it.
class _SeasonSelector extends StatefulWidget {
  const _SeasonSelector({
    required this.seasons,
    required this.selected,
    required this.onChanged,
  });

  final List<int> seasons;
  final int selected;
  final ValueChanged<int> onChanged;

  /// What one pill reads: the number alone, and season 0 by its name.
  static String label(int season) => season == 0 ? 'Specials' : '$season';

  /// How long the scroll that brings the selected pill into view takes.
  static const Duration revealDuration = Duration(milliseconds: 200);

  /// The space between two pills.
  static const double _gap = 8;

  /// Rounds the focus ring around a pill. A chip is stadium-shaped, and a
  /// radius this side of half its height is drawn as one (the radii are
  /// scaled down to fit the box, never up).
  static const BorderRadius _pillRadius = BorderRadius.all(Radius.circular(40));

  @override
  State<_SeasonSelector> createState() => _SeasonSelectorState();
}

class _SeasonSelectorState extends State<_SeasonSelector> {
  final ScrollController _controller = ScrollController();

  /// One key per season, so the reveal below can find the pill's box.
  final Map<int, GlobalKey> _pills = {};

  @override
  void initState() {
    super.initState();
    _revealSelected();
  }

  @override
  void didUpdateWidget(_SeasonSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected ||
        !listEquals(oldWidget.seasons, widget.seasons)) {
      _revealSelected();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Centres the selected pill in the row, once the frame that laid it out
  /// is on screen: the pill of a season chosen this frame has no box yet.
  void _revealSelected() {
    final season = widget.selected;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final box = _pills[season]?.currentContext?.findRenderObject();
      if (box == null) return;
      _controller.position.ensureVisible(
        box,
        alignment: 0.5,
        duration: _SeasonSelector.revealDuration,
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _pills.removeWhere((season, _) => !widget.seasons.contains(season));
    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text('Season', style: theme.textTheme.labelLarge),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // An even share of the row each, as a *minimum*: seasons that
              // fit spread over the whole width, and a series with too many
              // keeps them at their own width and scrolls. Filling the row
              // is what keeps the pills reachable on a television, where
              // directional focus coming down from the header prefers
              // whatever overlaps it horizontally -- a short row packed at
              // the left is stepped straight over into the episode list.
              //
              // Never below zero: past about thirty pills the gaps alone
              // are wider than the row, and a negative minimum is not a
              // cramped layout but a `NOT NORMALIZED` constraints failure
              // that takes the episode list down with it. A series that
              // long scrolls at its pills' own width, which is the same
              // thing an even share of nothing would be.
              final even =
                  (constraints.maxWidth -
                      _SeasonSelector._gap * (widget.seasons.length - 1)) /
                  widget.seasons.length;
              final share = even > 0 ? even : 0.0;
              return SingleChildScrollView(
                controller: _controller,
                scrollDirection: Axis.horizontal,
                child: Row(
                  spacing: _SeasonSelector._gap,
                  children: [
                    for (final season in widget.seasons)
                      ConstrainedBox(
                        key: _pills.putIfAbsent(season, GlobalKey.new),
                        constraints: BoxConstraints(minWidth: share),
                        // The same indicator every focusable thing on a
                        // television wears, rather than a ring of the
                        // pill's own: a chip's built-in focus highlight is
                        // a tint, which is exactly the cue a bright room
                        // takes away.
                        child: FocusHighlighted(
                          borderRadius: _SeasonSelector._pillRadius,
                          builder: (context, node) => ChoiceChip(
                            focusNode: node,
                            label: Text(_SeasonSelector.label(season)),
                            showCheckmark: false,
                            selected: season == widget.selected,
                            // Selected or not, every pill takes a press and
                            // is a focus stop: a chip with no callback is
                            // neither, which would leave a remote unable to
                            // rest on the season already on screen.
                            onSelected: (_) => widget.onChanged(season),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
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
    this.onDeleteDownload,
  });

  final VideoInfo video;
  final bool isSelected;
  final bool isWatched;
  final bool isReleased;

  /// This episode's download, whatever source it was taken from; null when
  /// it is not kept on the device.
  final DownloadView? download;

  /// Removes [download], which the badge offers once the file is whole.
  final void Function(DownloadView entry)? onDeleteDownload;
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
  ///
  /// The badge deletes the download once the file is whole. Not with a
  /// remote, though: a button inside a tile the remote activates as a whole
  /// cannot be focused, and this row's long press already means "watched",
  /// so on a television the episode's copy is removed from its stream tile
  /// -- select the episode, hold select on the release that is kept.
  Widget? _trailing(ThemeData theme) {
    final download = this.download;
    final state = isWatched
        ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
        : isSelected
        ? const Icon(Icons.play_arrow)
        : null;
    if (download == null) return state;
    final onDelete = onDeleteDownload;
    final badge = DownloadBadge(
      download: download,
      onDelete: onDelete == null ? null : () => onDelete(download),
    );
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

/// Every stream addon has answered and none of them had anything to play.
/// With the addons xtremio installs itself that is what a series episode
/// usually looks like -- none of them serves torrents -- so the section
/// says so in as many words and offers the screen that fixes it, rather
/// than leaving a heading over nothing.
class _NoStreamsNotice extends StatelessWidget {
  const _NoStreamsNotice({required this.isEpisode, required this.onAddons});

  /// Names what came up empty: an episode of a series, or the title.
  final bool isEpisode;
  final VoidCallback onAddons;

  static const String addonsLabel = 'Add an addon';

  String get title =>
      isEpisode ? 'No streams for this episode' : 'No streams for this title';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.search_off, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      'None of your sources had anything to play. xtremio '
                      'comes with no torrent addon, so add one and its '
                      'streams show up here.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: onAddons,
              icon: const Icon(Icons.extension_outlined),
              label: const Text(addonsLabel),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the stream section says between a tap on an episode and the
/// engine's answer.
const String kLookingForStreams = 'Looking for streams…';

/// What the toggle in the section header says the layout on screen right
/// now is, as its own short label (drawn beside it, when there is room)
/// and as the state half of its tooltip, so it reads as "here is where you
/// are" rather than as an action that only points one way.
const String kStreamsSectionedLabel = 'Sectioned by resolution';
const String kStreamsGroupedLabel = 'Grouped by addon';

/// The toggle's tooltip: the layout on screen right now, and what tapping
/// it switches to.
const String kStreamsSectionedTooltip =
    '$kStreamsSectionedLabel — tap to group by addon';
const String kStreamsGroupedTooltip =
    '$kStreamsGroupedLabel — tap to section by resolution';

/// The key on one resolution section's header.
///
/// A test (and anything else looking for a heading) has to be able to say
/// *which* section it means, and the label alone cannot: a 1080p row badges
/// itself `1080p` too, so the text is on the heading and on every row under
/// it.
Key streamSectionKey(StreamResolution? resolution) =>
    ValueKey('streams-section-${resolution?.label ?? 'unknown'}');

class _StreamsHeader extends StatelessWidget {
  const _StreamsHeader({
    super.key,
    required this.state,
    this.video,
    this.isLoading = false,
    this.sectioned = true,
    this.onSectionedChanged,
    this.order = StreamOrder.peersPerSize,
    this.onOrderChanged,
  });

  final MetaDetailsState state;

  /// Whether the list below is the one cut into resolution sections,
  /// rather than one section per addon.
  final bool sectioned;

  /// Flips the layout; null draws no toggle at all.
  final ValueChanged<bool>? onSectionedChanged;

  /// What order the streams inside each section are in. Only the sectioned
  /// layout has such an order to choose -- the grouped one is the addons'
  /// own ranking, which is the whole point of it -- so the chips are drawn
  /// only there.
  final StreamOrder order;

  /// Picks that order; null draws no chips.
  final ValueChanged<StreamOrder>? onOrderChanged;

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
    final onOrderChanged = this.onOrderChanged;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                    // States which of the two layouts is on screen, right
                    // next to the heading -- the toggle's tooltip says the
                    // same thing, for when there is no room to read this.
                    if (onSectionedChanged != null)
                      Text(
                        sectioned
                            ? kStreamsSectionedLabel
                            : kStreamsGroupedLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (subtitle != null)
                      Text(subtitle, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              if (onSectionedChanged != null)
                IconButton(
                  tooltip: sectioned
                      ? kStreamsSectionedTooltip
                      : kStreamsGroupedTooltip,
                  icon: Icon(
                    sectioned ? Icons.view_agenda_outlined : Icons.sort,
                  ),
                  onPressed: () => onSectionedChanged!(!sectioned),
                ),
              if (isLoading || state.isLoadingStreams)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          // A Wrap rather than a row of segments: three labels have to fit
          // a phone's width and a 480 dp pane on a television, and the
          // chips are each a focus stop a remote can reach.
          if (sectioned && onOrderChanged != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: FilterChips<StreamOrder>(
                options: [
                  for (final choice in StreamOrder.values)
                    FilterOption(
                      label: choice.label,
                      selected: choice == order,
                      request: choice,
                    ),
                ],
                onSelect: onOrderChanged,
              ),
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

/// One row of the sources list, in either layout: the stream as it will be
/// played -- with the trackers every listing of it named -- the addon group
/// it came from (a download records the request its stream came from, so
/// the group has to travel with it), what could be read out of it (the flat
/// list only; the grouped one has a heading and [StreamHints]) and the
/// other addons that offered the same source.
typedef _SourceRow = ({
  StreamGroup group,
  StreamInfo stream,
  StreamFacts? facts,
  List<String> alsoFrom,
});

/// What a stream tile knows about offline downloads: the entry for its
/// stream if the registry has one, whether a pin for it is in flight, how
/// to start one and how to drop one. Bound to the addon group the tile sits
/// in, because a pin records the request its stream came from.
final class _StreamDownloads {
  const _StreamDownloads({
    required this.videoEntry,
    required this.isPending,
    required this.onDownload,
    required this.onDelete,
    this.group,
  });

  /// The download of the video these tiles belong to, from any source.
  final DownloadView? Function() videoEntry;
  final bool Function(StreamInfo stream) isPending;
  final void Function(StreamGroup group, StreamInfo stream) onDownload;

  /// Removes one, after asking what becomes of the file. Unlike a download
  /// this needs no group: an entry names the stream it was taken from.
  final void Function(DownloadView entry) onDelete;

  /// The addon group; null until [forGroup] binds one, which is when a tile
  /// can offer to download at all.
  final StreamGroup? group;

  _StreamDownloads forGroup(StreamGroup group) => _StreamDownloads(
    videoEntry: videoEntry,
    isPending: isPending,
    onDownload: onDownload,
    onDelete: onDelete,
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

/// One resolution's worth of the sources list: a header that says what it
/// holds whether or not it is open, and the streams under it when it is.
///
/// A collapsed header is not a placeholder: it says how many streams are
/// folded away and the best swarm among them ([StreamSection.summary]), so
/// a 2160p section with one dead torrent in it is told from a healthy one
/// without opening either. It is an ordinary [ListTile] with an `onTap`,
/// which is what makes a remote able to reach it and open it: a television
/// walks the pane by focusable nodes, and a header that could not take
/// focus would put every section below the first one out of reach.
class _ResolutionSectionSliver extends StatelessWidget {
  const _ResolutionSectionSliver({
    required this.section,
    required this.expanded,
    required this.onExpand,
    required this.lastUsed,
    required this.onPlay,
    this.autofocusIndex,
    this.headerAutofocus = false,
    this.downloads,
  });

  final StreamSection<_SourceRow> section;
  final bool expanded;
  final VoidCallback onExpand;

  /// The stream pinned as "Continue with last source", highlighted here too.
  final StreamInfo? lastUsed;
  final ValueChanged<_SourceRow> onPlay;

  /// The stream (by index) where TV focus starts; null for none here.
  final int? autofocusIndex;

  /// Whether TV focus starts on this section's own header. Only true when
  /// every section is collapsed and there is no stream to focus instead --
  /// see `headerAutofocusAt` in `_streamSlivers`.
  final bool headerAutofocus;

  /// The downloads, when there is a client above this screen. Bound to each
  /// row's own group, since a pin records the request its stream came from.
  final _StreamDownloads? downloads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: ListTile(
            key: streamSectionKey(section.resolution),
            autofocus: headerAutofocus,
            leading: Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              section.label,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            subtitle: Text(section.summary),
            onTap: onExpand,
          ),
        ),
        if (expanded)
          SliverList.builder(
            itemCount: section.rows.length,
            itemBuilder: (context, index) {
              final row = section.rows[index];
              final lastUsed = this.lastUsed;
              return _StreamTile(
                stream: row.stream,
                facts: row.facts,
                alsoFrom: row.alsoFrom,
                highlighted:
                    lastUsed != null && row.stream.isSameSource(lastUsed),
                onTap: row.stream.isPlayable ? () => onPlay(row) : null,
                autofocus: index == autofocusIndex,
                downloads: downloads?.forGroup(row.group),
              );
            },
          ),
      ],
    );
  }
}

/// One addon's answer: its label and the streams under it, or a spinner
/// while they are still on their way.
///
/// Only groups with something to show reach here. An addon that *failed* is
/// collected into [FailedAddonsSection], and one that answered with
/// nothing into [_EmptyAddonsSummary], both below the streams that did
/// arrive.
class _StreamGroupSliver extends StatelessWidget {
  const _StreamGroupSliver({
    required this.group,
    required this.rows,
    required this.lastUsed,
    required this.onPlay,
    this.autofocusIndex,
    this.downloads,
  });

  final StreamGroup group;

  /// What to list under the heading: the group's streams with this addon's
  /// own repeats collapsed and every one of them carrying the trackers the
  /// other addons named for the same source.
  final List<_SourceRow> rows;

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
    final label = group.isFromMeta
        ? 'From ${group.addonLabel}'
        : group.addonLabel;
    // Nothing yet, as opposed to nothing at all: a group that settled on
    // no streams is not listed here at all any more, so the label with a
    // spinner under it can only mean the answer is still coming.
    final waiting = rows.isEmpty && group.isLoading;
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
        if (waiting)
          const SliverToBoxAdapter(
            child: ListTile(
              dense: true,
              leading: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text(kLookingForStreams),
            ),
          ),
        SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final stream = rows[index].stream;
            final lastUsed = this.lastUsed;
            return _StreamTile(
              stream: stream,
              alsoFrom: rows[index].alsoFrom,
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

/// The addons that answered this video with nothing, as one quiet line
/// below the streams that did arrive.
///
/// Most stream addons have nothing for most episodes, so listing each as a
/// labelled section with "No streams" under it filled the pane with the
/// addons that had nothing to say and pushed the ones that did off the
/// screen. The count is kept, because "four addons were asked and had
/// nothing" and "no addon has answered yet" are different answers, and the
/// row expands to name them.
class _EmptyAddonsSummary extends StatefulWidget {
  const _EmptyAddonsSummary({required this.names, required this.isEpisode});

  /// The addons, named from the profile where it knows them.
  final List<String> names;

  /// Whether the streams are an episode's, for the wording.
  final bool isEpisode;

  static String summaryLabel(int count, {required bool isEpisode}) =>
      '$count ${count == 1 ? 'addon' : 'addons'} had nothing for this '
      '${isEpisode ? 'episode' : 'title'}';

  @override
  State<_EmptyAddonsSummary> createState() => _EmptyAddonsSummaryState();
}

class _EmptyAddonsSummaryState extends State<_EmptyAddonsSummary> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final names = widget.names;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          leading: Icon(Icons.inbox_outlined, color: muted),
          title: Text(
            _EmptyAddonsSummary.summaryLabel(
              names.length,
              isEpisode: widget.isEpisode,
            ),
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
          subtitle: _expanded
              ? null
              : Text(
                  names.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            color: muted,
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded)
          for (final name in names)
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
              child: Text(
                name,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
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
    this.facts,
    this.alsoFrom = const [],
  });

  final StreamInfo stream;

  /// The other addons that offered this very source, when more than one
  /// did. The row is one of them (the best-ranked, or the one whose group
  /// this is), and this is how it says the others are not missing but the
  /// same thing again. Empty says nothing at all -- including for a source
  /// one addon listed twice, which is the addon repeating itself.
  final List<String> alsoFrom;

  /// In the flat list, what was read out of the stream: the row says which
  /// addon answered (there is no heading above it any more) and carries a
  /// badge for each thing that is actually known -- an unknown gets no
  /// badge rather than a placeholder. Null is the grouped list, where the
  /// heading names the addon and the chips come from [StreamHints].
  final StreamFacts? facts;
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
    final facts = this.facts;
    final title = titleOverride ?? stream.title;
    // A name that is nothing but the hint ("1080p") needs no chip for it.
    final chips = facts != null
        ? facts.badges
        : [
            for (final chip in hints.chips)
              if (chip.toLowerCase() != stream.title.toLowerCase()) chip,
          ];
    final description = facts != null
        ? facts.addonName
        : titleOverride != null
        ? stream.title
        : stream.name == null
        ? null
        : hints.strip(stream.description);
    final isTv = DeviceScope.isTv(context);
    final alsoFrom = this.alsoFrom.isEmpty
        ? null
        : alsoFromLabel(this.alsoFrom);
    final lines =
        [description, alsoFrom].nonNulls.length + (chips.isEmpty ? 0 : 1);
    final tile = ListTile(
      enabled: onTap != null,
      selected: highlighted,
      autofocus: autofocus,
      leading: Icon(leadingIcon ?? _iconFor(stream.kind)),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: lines > 1,
      subtitle: lines == 0
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
                if (alsoFrom != null)
                  Text(
                    alsoFrom,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
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
    if (!isTv) return withTooltip;
    return RemotePress(
      onTap: onTap,
      onLongPress: _remoteDownloadAction(),
      child: withTooltip,
    );
  }

  /// What the download button on this tile does, for a remote that cannot
  /// press it.
  ///
  /// Directional traversal skips a node inside the focused one's rect, and
  /// the button is inside the tile the remote activates as a whole, so on a
  /// television it can be looked at and never reached. The tile's long
  /// press -- hold select, or the remote's menu key -- is the "more
  /// options" gesture everywhere else in the app, and here there is exactly
  /// one option: whatever the button beside the play arrow would do. Null
  /// while there is nothing to do (no client, a stream the server cannot
  /// keep, a pin in flight, a download still arriving), which leaves a hold
  /// meaning what it meant before -- a tap on release.
  VoidCallback? _remoteDownloadAction() {
    final downloads = this.downloads;
    if (downloads == null || downloads.isPending(stream)) return null;
    final entry = downloads.entryOf(stream);
    if (entry == null) return downloads.starter(stream);
    return switch (entry.state) {
      DownloadState.complete => () => downloads.onDelete(entry),
      DownloadState.error => downloads.starter(stream),
      _ => null,
    };
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
  /// ring while it arrives, a button that deletes it once it is on the
  /// device, and the error as a button that pins again. Nothing at all for
  /// a stream the server cannot keep (anything but a torrent) or with no
  /// client above.
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
      // The finished state is a button, not a tick: the picker that took
      // the download is where the user is when they decide they do not
      // want it any more, and the tick said the same thing while doing
      // nothing. It keeps the primary colour of the tick it replaces, so
      // the row still reads as "this one is on the device".
      DownloadState.complete => IconButton(
        tooltip: kDownloadDeleteTooltip,
        color: Theme.of(context).colorScheme.primary,
        icon: const Icon(Icons.delete_outline),
        onPressed: () => downloads.onDelete(entry),
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

/// The non-pressable half of the download affordance: a progress ring, or
/// a spinner while there is no fraction to show, padded to the size of the
/// [IconButton] it stands in for so the tile does not jump when the state
/// changes.
class _DownloadIndicator extends StatelessWidget {
  const _DownloadIndicator({required this.tooltip, this.progress});

  final String tooltip;

  /// `0..1` of the file; null spins.
  final double? progress;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2, value: progress),
      ),
    ),
  );
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
