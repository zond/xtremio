import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/external_link.dart';
import '../../shell/tv_density.dart';
import '../../widgets/download_badge.dart';
import '../../widgets/filter_controls.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/tv_ladder.dart';
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
import '../similar/similar_resolver.dart';
import 'episode_thumbnail.dart';
import 'similar_row.dart';
import 'stream_facts.dart';
import 'stream_sources.dart';
import 'tv_backdrop.dart';
import 'tv_episode_row.dart';
import 'tv_meta_header.dart';
import 'tv_source_row.dart';

/// The rungs of the television ladder that collapse: one of them is open
/// and the rest are a header line each (see [TvLadderRung]).
///
/// The title's own block is not among them -- it is what the screen is
/// about, and it is always on the panel -- and neither is anything a
/// viewer cannot be left standing in front of with nothing to press.
enum _DetailsRung {
  /// The one card that carries on from where the viewer left off.
  continueWatching,

  /// The season's episodes, and the season pills above them.
  episodes,

  /// The groups of sources and whichever group's row is out.
  sources,

  /// What a model says this title is like ([SimilarTitlesRow]).
  ///
  /// The one rung the screen never opens by itself. Its answer arrives
  /// seconds after the screen does and sometimes not at all, so a rung
  /// that could be the open one would be a screen whose shape depends on
  /// when a stranger's server replied. It opens when the viewer presses
  /// select on its header and at no other time.
  moreLikeThis,

  /// What the addons did other than answer with streams.
  addons,
}

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
/// The addon groups collapse the same way and remember the same way, in
/// [AppPrefs.openStreamAddons] -- a key of its own, because an addon may
/// be called what a resolution is called and because the two layouts ask
/// different questions. Nothing remembered means every group shut, on a
/// fresh install and after the last one is closed; a remembered addon this
/// title has no sources from is not shown open and never stands in for
/// another group. A closed group's header says how many streams it holds,
/// which is all this layout knows without parsing rows it is not asked to
/// rank.
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
/// On a TV the title's artwork is behind the whole screen ([TvBackdrop])
/// and the header over it is the logo, one line of facts and two lines of
/// description ([TvMetaHeader]) rather than the poster and the collapsing
/// hero a phone shows: at three metres the poster was a third of the
/// layout and the rows are what the remote came for.
///
/// The episodes are one of those rows there ([TvEpisodeRow]) rather than
/// the vertical list a phone and a desktop keep: a remote walks a row with
/// two keys and a list with a hundred, and the panel has width to spare
/// and no height at all once the backdrop and the sources are on it. The
/// season pills above it were already a row.
///
/// The sources are rows there too ([TvSourceRows]), and not a pane beside
/// the episodes: a card per resolution rung or per addon -- whichever the
/// layout preference already says -- and, under whichever card is chosen,
/// a row of that group's sources. So the whole television screen is one
/// column of rows the remote walks with four keys, and Back comes down a
/// ladder like the player's: the open row of sources first, the screen
/// second.
///
/// Focus starts on the source the user most likely wants (the last used
/// one, else the first group card) as nothing else on a freshly pushed
/// screen holds any, the remote's menu key or a held select on an episode
/// is its long press (toggle watched), and a long season list is picked
/// from a [FilterMenu] rather than a dropdown.
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

  /// How many times any details screen has derived its sources list from
  /// scratch (see `_StreamDerivation`). A derivation is a handful of
  /// regexes per stream, a sort and a sectioning; the tests pin that a
  /// rebuild which changed none of its inputs -- a download's progress
  /// tick, once a second -- does not pay for it again.
  @visibleForTesting
  static int debugStreamDerivations = 0;

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

  /// This title's rows as the last tick left them (see
  /// [_onDownloadsChanged]).
  List<DownloadView> _downloadsSeen = const [];

  /// The sources list as last derived, kept while its inputs stand (see
  /// [_deriveStreams]).
  _StreamDerivation? _derived;

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

  /// The rungs of this screen's [TvLadder], top to bottom: the choices a
  /// viewer makes on the way to a stream, in the order they make them.
  ///
  /// Numbered with gaps because most of them are conditional -- a film has
  /// no seasons or episodes, a title nobody has played has no last-used
  /// source, and the row of sources only exists while a group is open.
  /// Only what is drawn is registered, and a press walks past the rest.
  /// The block above the pills: on a television that is the title, its
  /// facts and the bookmark. A rung, so a press down from the bookmark
  /// reaches the pills instead of whatever geometry finds below a narrow
  /// row packed at the left -- which was the episode row on a good day and
  /// the heading's controls on a bad one, and either way left the episode
  /// row arrived at sideways, with its memory of where the viewer was
  /// overwritten by wherever the press landed.
  /// On a television most of these sit inside a [TvLadderRung], whose
  /// header is a rung of the walk in its own right: the walk goes header,
  /// header, header down the screen, and only the open rung puts its own
  /// rows between two of them.
  ///
  /// **These are the order things are drawn down the panel, and the two
  /// are one list even though they are built by two methods.** The title
  /// and the episodes come from [_infoSlivers] and everything from the
  /// last-used source down from [_tvSourceSlivers], and the screen lays
  /// them out info-then-sources -- so the continue-watching rung is
  /// *below* the episodes on the panel, whatever order the two methods are
  /// called in. It was numbered above them, and a press up from the
  /// last-used card went to the title and stepped over the episodes
  /// entirely: the ladder walks these numbers and the viewer walks the
  /// panel, so a number out of order is a rung the D-pad cannot reach from
  /// its neighbour.
  static const int _ladderInfo = 0;
  static const int _ladderEpisodesHeader = 20;
  static const int _ladderSeasons = 24;
  static const int _ladderEpisodes = 28;
  static const int _ladderLastUsedHeader = 30;
  static const int _ladderLastUsed = 35;
  static const int _ladderSourcesHeader = 40;
  static const int _ladderStreamControls = 43;
  static const int _ladderStreamOrder = 46;
  static const int _ladderGroups = 50;
  static const int _ladderSources = 55;
  static const int _ladderSimilarHeader = 60;
  static const int _ladderSimilar = 65;
  static const int _ladderAddonsHeader = 70;
  static const int _ladderAddons = 75;

  /// The load a walk along the episode row is waiting to make; see
  /// [_focusVideo].
  Timer? _focusSelect;

  /// The episode the last build drew as the selected one, so resting on it
  /// again is recognised as choosing nothing; see [_focusVideo].
  String? _shownVideoId;

  /// How long the remote has to stand still on an episode before its
  /// sources are asked for.
  ///
  /// Walking a season is one focus change per press, and each one would
  /// otherwise be a `Load` of that episode's streams: every addon asked
  /// about every episode the remote passed over. A wait is what tells
  /// passing through from arriving, and it is short enough that a viewer
  /// who has stopped does not notice it.
  static const Duration _focusSelectDelay = Duration(milliseconds: 350);

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

  /// Whether the last build was the television one: one column of rows,
  /// where nothing scrolls itself either (the remote's focus is what
  /// moves, and a scroll of our own would fight it).
  bool _isTv = false;

  /// The [TvSourceGroup.label] whose sources are the second row, on a
  /// television; null with only the group row on screen.
  ///
  /// Deliberately not [AppPrefs.openStreamSections]: that is a *set* of
  /// resolutions, global and remembered across restarts, and this is one
  /// row at a time that Back closes. They share a word and nothing else.
  /// It is a label rather than an index so that streams arriving late,
  /// which re-section the list under it, cannot silently move the mark to
  /// another group.
  String? _openSourceGroup;

  /// The group whose row Back has just put away, which the card it was
  /// opened from must not reopen when focus lands back on it.
  ///
  /// Closing the row takes the card the remote was on off the screen, and
  /// the scope hands focus back to the group card above -- a gain of
  /// focus like any other, which would otherwise reopen the very row the
  /// press had just closed and leave Back looking broken. It is cleared
  /// the moment focus reaches any other card, or the viewer presses this
  /// one again.
  String? _reopenSuppressed;

  /// Whether the build now in progress has actually drawn a row for
  /// [_openSourceGroup]: a rung the last state offered and this one does
  /// not leaves the label naming nothing, and the row went with it.
  ///
  /// Back has to ask this rather than whether the label is set, or a
  /// stale one swallows a whole press with nothing happening on screen --
  /// which happens whenever the streams are re-fetched, a dead addon
  /// comes back, or an episode is picked from the row above while a
  /// resolution is open.
  bool _openSourceRowDrawn = false;

  /// The rung the viewer has settled on: the one they pressed select on,
  /// or -- when they have walked away without choosing -- whichever was
  /// open when they first moved the remote. Null while the screen is still
  /// the one deciding (see [_rungToOpen]).
  _DetailsRung? _chosenRung;

  /// Whether the viewer has shut the rung they had open, leaving the
  /// ladder a stack of header lines with nothing out.
  ///
  /// **What closing the chosen rung means, since it had to mean
  /// something.** The rungs are one at a time, so shutting the open one
  /// leaves no other rung for the press to fall back to -- and reopening
  /// the next one down would be answering select with a rung the viewer
  /// did not ask for. So it shuts the ladder: the title block and the
  /// header lines, which is the contents page this ladder collapses into
  /// and a perfectly good thing to be looking at. The remote is not moved,
  /// because the header that was pressed is one of those lines and is
  /// still on the panel: what goes away is entirely below it.
  ///
  /// Kept apart from [_chosenRung] rather than folded into it as a null,
  /// because null there means the screen has not been told yet and falls
  /// back to the arrival order ([_rungToOpen]) -- which would open again,
  /// on the same frame, the rung the press had just shut.
  bool _rungsShut = false;

  /// The rung the last build drew open, so a move of the remote can freeze
  /// it (see [_watchTheRemote]) without the listener having to work out
  /// what is on screen.
  _DetailsRung? _shownRung;

  /// The node the last-used source card focuses with, so the screen can
  /// put the remote there itself; see [_takeTheRemoteToTheLastUsed].
  final FocusNode _lastUsedNode = FocusNode(debugLabel: 'last-used source');

  /// How "More like this" is asked, from the [SimilarScope] above this
  /// screen (absent, a [MoreLikeThis] of the screen's own). Read once,
  /// because the question is asked once.
  late final SimilarAskBuilder _askSimilar = SimilarScope.of(context);

  /// Whether the question has gone out for this title, which is also the
  /// answer to *is the feature on*: with no key configured nothing is
  /// asked and no rung is drawn ([_maybeAskSimilar]).
  bool _similarAsked = false;

  /// What came back: the titles a catalogue confirmed, in the model's
  /// order. Null while the ask is out -- which is where the header says it
  /// is looking -- and empty when the model had nothing or the guard
  /// dropped all of it, which takes the rung away again.
  List<SimilarTitle>? _similar;

  /// Whether a re-ask is out ([_askSimilarAgain]).
  ///
  /// One ask at a time, and this is the guard rather than a disabled
  /// control: the television's card keeps its tap for as long as the
  /// remote may be standing on it, so four presses in a row have to cost
  /// one call here.
  bool _reasking = false;

  /// Whether there is a "More like this" rung on the panel at all.
  ///
  /// Three states and not two: never asked (no key) and asked-and-empty
  /// both draw nothing, and the wait between them is a header that says
  /// it is looking. A feature that is off says nothing about itself --
  /// there is no "configure a key" line here, because a viewer who has
  /// not set one up is not being sold anything.
  bool get _hasSimilar =>
      _similarAsked && (_similar == null || _similar!.isNotEmpty);

  /// Where the remote was first put down on this screen, and whether it
  /// has left. Where it starts is the screen's to choose; after that it is
  /// the viewer's, and nothing drawn later takes it off what they walked
  /// to.
  FocusNode? _startedOn;
  bool _remoteHasMoved = false;

  /// Whether the screen has taken the remote to the last-used card, which
  /// it does at most once -- on arrival, when that card turns up.
  bool _tookTheRemote = false;

  /// Follows the remote, so [_takeTheRemoteToTheLastUsed] can tell the
  /// focus the screen chose from the focus the viewer chose.
  void _watchTheRemote() {
    final node = FocusManager.instance.primaryFocus;
    // A scope is what holds focus between one tile losing it and the next
    // taking it -- a row closing, a sliver rebuilt -- and is nowhere the
    // viewer can have moved the remote to.
    if (node == null || node is FocusScopeNode) return;
    if (_startedOn == null) {
      _startedOn = node;
      return;
    }
    if (node == _startedOn || _remoteHasMoved) return;
    _remoteHasMoved = true;
    // The remote has left where the screen put it, so which rung is open
    // is the viewer's from here: a last-used source arriving late must not
    // shut the rung they walked into. Whatever is open when they move is
    // what they are looking at, even though they never pressed select on
    // its header.
    _chosenRung ??= _shownRung;
  }

  /// Puts the remote on the last-used card, the first time that card is
  /// drawn and only while the remote is still where the screen put it.
  ///
  /// The card's own autofocus is not enough. The addons answer with
  /// streams before the engine has said which source the title was last
  /// played from, so the sources rung below is built first and takes the
  /// start of the screen -- and Flutter drops an autofocus asked for by a
  /// widget built into a scope that already has a focused child. Opening a
  /// title from a continue-watching card left the remote a row below the
  /// one card that continues it, which is several presses from the one
  /// thing the viewer came to do.
  ///
  /// Never off a card the viewer walked to: the player writes the
  /// last-used source down while it is up, so coming back from it draws
  /// this card for the first time on a screen the viewer is already using.
  /// Decided here, while the build that draws the card is still running:
  /// by the frame this lands on, the rung the remote was standing in has
  /// closed under it and the scope has handed the ring elsewhere, so
  /// asking again then would be asking about the screen's own doing.
  void _takeTheRemoteToTheLastUsed() {
    if (_tookTheRemote || _remoteHasMoved) return;
    _tookTheRemote = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastUsedNode.requestFocus();
    });
  }

  /// Which rung of the collapsing ladder is open.
  ///
  /// **What is open on arrival is whatever the title is for.** A viewer who
  /// has played this title before came back to carry on, so the rung with
  /// the last-used source on it is out and select plays it; a series they
  /// have not played is a choice of episode; a film they have not played is
  /// a choice of source. Rung zero would be right for none of them.
  ///
  /// Once the viewer has chosen -- select on a header, or simply walking
  /// the remote off where the screen put it ([_watchTheRemote]) -- that
  /// choice stands, and a rung arriving late does not move it. The
  /// last-used source is written down by the player and comes back seconds
  /// after the streams do; that is the same bug as leaving the remote where
  /// it was, wearing a different hat.
  ///
  /// A rung that is not drawn cannot be open, so a choice the next state
  /// has nothing for falls back to the arrival order rather than leaving
  /// the screen with nothing out. A viewer who shut the rung they had open
  /// is the one case where nothing being out is the answer ([_rungsShut]):
  /// they asked for it, and a late arrival does not undo it.
  ///
  /// [_DetailsRung.moreLikeThis] is in what is *drawn* and not in that
  /// arrival order: a viewer can open it and stay in it, and nothing else
  /// ever will. See the rung.
  _DetailsRung? _rungToOpen(
    MetaDetailsState state, {
    required bool hasLastUsed,
    required bool hasSources,
    required bool hasAddons,
  }) {
    if (_rungsShut) return null;
    final drawn = {
      if (hasLastUsed) _DetailsRung.continueWatching,
      if (state.hasVideos) _DetailsRung.episodes,
      if (hasSources) _DetailsRung.sources,
      if (_hasSimilar) _DetailsRung.moreLikeThis,
      if (hasAddons) _DetailsRung.addons,
    };
    final chosen = _chosenRung;
    if (chosen != null && drawn.contains(chosen)) return chosen;
    for (final rung in [
      _DetailsRung.continueWatching,
      if (state.hasVideos) _DetailsRung.episodes,
      _DetailsRung.sources,
      _DetailsRung.episodes,
      _DetailsRung.addons,
    ]) {
      if (drawn.contains(rung)) return rung;
    }
    return null;
  }

  /// Select on a rung's header: this one opens, and whichever was open
  /// closes with it -- unless this *is* the one that was open, in which
  /// case it closes and the ladder is left shut ([_rungsShut]).
  ///
  /// A header that only ever opens is a control that lies about being a
  /// toggle, and on a television it is worse than on a phone: there is no
  /// scrollbar and no gesture to put away a rung opened to look at one
  /// thing. The chevron on the line says open or shut, and this is what
  /// makes the press match it.
  ///
  /// [_shownRung] and not [_chosenRung] is what the press is measured
  /// against: what a viewer means by "the one that is open" is the one
  /// they can see out, which is what the last build drew.
  void _selectRung(_DetailsRung rung) => setState(() {
    _rungsShut = _shownRung == rung;
    _chosenRung = rung;
  });

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_watchTheRemote);
  }

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
      _downloadsSeen = const [];
      _downloads = downloads == null
          ? null
          : (DownloadsController(downloads)..addListener(_onDownloadsChanged));
    }
    trackRoute();
    // A key can arrive after the title has: the preferences are read
    // asynchronously at start-up, and the settings screen where one is
    // pasted in is a few presses from here. [PrefsScope] is an
    // `InheritedNotifier`, so a key written anywhere runs this again --
    // which is the only moment a screen already on the stack has to
    // notice one.
    final state = ownState;
    if (state != null) _maybeAskSimilar(state);
  }

  /// A tick moved some download's numbers. Only a change to one of *this
  /// title's* rows is drawn here: the ticker reports every row that moved,
  /// once a second, for as long as anything is downloading, and a screen
  /// sitting under the player while another title comes in has nothing to
  /// redraw for it. Rows are compared by the map behind each view -- a
  /// progress tick replaces the maps of the rows it moved and keeps the
  /// others, so identity is the whole test.
  void _onDownloadsChanged() {
    final downloads = _downloads;
    if (!mounted || downloads == null) return;
    final rows = downloads.ofMeta(widget.id);
    if (_sameRows(rows, _downloadsSeen)) return;
    _downloadsSeen = rows;
    setState(() {});
  }

  static bool _sameRows(List<DownloadView> a, List<DownloadView> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i].json, b[i].json)) return false;
    }
    return true;
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
    FocusManager.instance.removeListener(_watchTheRemote);
    _lastUsedNode.dispose();
    _focusSelect?.cancel();
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
    _maybeAskSimilar(state);
  }

  /// Asks what this title is like, once, as soon as the title itself is
  /// known -- its name and year are the question.
  ///
  /// **With no key configured nothing is asked.** The feature answers
  /// every failure with an empty list, a missing key included, so asking
  /// anyway would work; it is the *rung* that cannot wait for that answer.
  /// A header that appeared and then went away again on every title a
  /// viewer who has configured nothing opens is worse than no row, so the
  /// one thing the screen reads for itself is whether there is a key.
  void _maybeAskSimilar(MetaDetailsState state) {
    final meta = state.meta;
    final prefs = _prefs;
    if (!mounted || _similarAsked || meta == null || prefs == null) return;
    if (prefs.similarApiKey == null) return;
    _similarAsked = true;
    unawaited(_similarFor(meta, prefs));
  }

  Future<void> _similarFor(MetaItem meta, AppPrefs prefs) async {
    final titles = await _askSimilar(prefs)(
      type: widget.type,
      id: widget.id,
      name: meta.name,
      year: yearIn(meta.releaseInfo),
    );
    // Late by design -- three seconds is the good case. Everything about
    // what this must not disturb on the way in is in [_tvSimilarRung].
    if (mounted) setState(() => _similar = titles);
  }

  /// The viewer has said this row is wrong: ask the model again about the
  /// title on screen, past everything remembered about it.
  ///
  /// **A press may not leave them with less than they had.** Every failure
  /// down there is an empty list by design ([MoreLikeThis]), so a provider
  /// that is gone and a model with nothing to say arrive looking the same,
  /// and neither is grounds for blanking a row somebody was looking at
  /// when they pressed -- on a television, one they may be standing in.
  /// So the rule is one rule for both: the row is replaced only when
  /// something came back to replace it with, and otherwise the
  /// suggestions stand, unchanged on the panel and unchanged in the
  /// preferences file, and the viewer is told once. A press that changed
  /// nothing and said nothing is a dead button.
  Future<void> _askSimilarAgain() async {
    final meta = ownState?.meta;
    final prefs = _prefs;
    if (_reasking || meta == null || prefs == null) return;
    setState(() => _reasking = true);
    final List<SimilarTitle> titles;
    try {
      titles = await _askSimilar(prefs)(
        type: widget.type,
        id: widget.id,
        name: meta.name,
        year: yearIn(meta.releaseInfo),
        afresh: true,
      );
    } finally {
      if (mounted) setState(() => _reasking = false);
    }
    if (!mounted) return;
    if (titles.isEmpty) {
      _tell(kNothingNewSimilar);
      return;
    }
    setState(() => _similar = titles);
  }

  /// The episode the screen shows as selected: the tap in flight, else the
  /// engine's own selection.
  String? _selectedVideoId(MetaDetailsState state) =>
      _awaitingVideoId ?? state.streamPath?.id;

  /// How far into [video] the library says the viewer got, `0..1`, or null
  /// when it says nothing about this episode.
  ///
  /// The engine keeps one resume point per title (`libraryItem.state`), so
  /// this answers for at most one episode of a series -- the last one
  /// played -- and null for every other. That is the whole of what is
  /// known: there is no per-episode progress to read, and inventing one
  /// from the watched list would draw a bar nobody's viewing produced.
  double? _resumeProgress(MetaDetailsState state, VideoInfo video) {
    final item = state.libraryItem;
    if (item == null || item.videoId != video.id) return null;
    return item.progress;
  }

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
    // The open row is left where it is. Choosing a new season, episode or
    // group refreshes what is *below* it; it does not put away a row the
    // viewer has already chosen, because the move that asked for this is
    // usually a step along a path they picked -- the same resolution of
    // the next episode, say. A label the new answer has no group for draws
    // no row anyway ([_openSourceRowDrawn]), so nothing has to be cleared
    // for that either.
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
  /// the streams pane is beside the episode and answers for itself. On a
  /// television there is nothing to scroll *with*: the sources are the row
  /// below the episodes and the remote is what walks to them, so a scroll
  /// of the screen's own would take the card the press was made on out
  /// from under the focus that is still on it.
  void _selectVideo(VideoInfo video, {bool reveal = false}) {
    // A press answers for itself: whatever the walk was about to ask for,
    // this is the episode the viewer means.
    _focusSelect?.cancel();
    _load(video.id);
    final acknowledge = reveal && !_isWide && !_isTv;
    if (acknowledge) _awaitingVideoId = video.id;
    if (mounted) setState(() => _season = video.season);
    if (acknowledge) _revealStreams(atEnd: true);
  }

  /// The remote has come to rest on a group card: open its sources,
  /// unless this is the card Back has just closed one from (see
  /// [_reopenSuppressed]).
  void _focusSourceGroup(String label) {
    if (_reopenSuppressed == label) {
      _reopenSuppressed = null;
      return;
    }
    setState(() {
      _openSourceGroup = label;
      _reopenSuppressed = null;
    });
  }

  /// The remote has come to rest on [video] in the episode row: show its
  /// sources, once it has stood there for [_focusSelectDelay].
  ///
  /// The highlight is what says which episode the rows below are about, so
  /// walking the row updates them and select is left to mean "play this",
  /// one press deeper. Nothing is asked for an episode already loaded --
  /// walking away and back costs nothing.
  void _focusVideo(VideoInfo video) {
    // Nothing has been chosen: this is the episode whose sources are
    // already on screen, which the remote passes back over on its way
    // along the row (and lands on when it first arrives from below).
    // Asking again would re-ask every addon and refresh rows that are
    // already right.
    if (video.id == _requestedVideoId || video.id == _shownVideoId) return;
    _focusSelect?.cancel();
    _focusSelect = Timer(_focusSelectDelay, () {
      if (mounted) _selectVideo(video);
    });
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
    if (_isWide || _isTv) return;
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
    Map<String, dynamic>? playback;
    if (client != null &&
        download != null &&
        download.isComplete &&
        download.stream.isSameSource(stream)) {
      playback = await offlinePlayback(client, download);
      if (!mounted) return;
    }
    if (!mounted) return;
    final result = await Navigator.of(context).push<PlayerScreenResult>(
      MaterialPageRoute<PlayerScreenResult>(
        settings: const RouteSettings(name: PlayerScreen.routeName),
        builder: (_) => PlayerScreen(
          stream: playback ?? stream.json,
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

  /// Drops the download of [entry], and its bytes, once the user has
  /// confirmed -- the Downloads list's own question, asked here so the tile
  /// that started a download is the tile that undoes it.
  ///
  /// The dialog is modal, so it is the guard against a second press while
  /// it stands, and a dismissed one removes nothing.
  Future<void> _deleteDownload(DownloadView entry) async {
    final client = _downloadsClient;
    final downloads = _downloads;
    if (client == null || downloads == null) return;
    if (!await askToRemoveDownload(context, entry) || !mounted) return;
    DownloadRemoveResult? result;
    try {
      result = await client.remove(entry.key, deleteFiles: true);
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
    _isTv = isTv;
    // Built here rather than inside the [LayoutBuilder] below because the
    // sources are the same list at every width, and because building them
    // is what answers [_openSourceRowDrawn] -- which the `PopScope` a few
    // lines down reads. A `LayoutBuilder` runs at layout, after the widget
    // above it was built, so the answer would be a frame old there.
    final streams = _streamSlivers(state, meta);
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final isWide =
            !isTv && constraints.maxWidth >= MetaDetailsScreen.wideBreakpoint;
        _isWide = isWide;
        final info = _infoSlivers(state, meta, isWide: isWide, isTv: isTv);
        if (!isWide) {
          return TvLadder(
            child: CustomScrollView(
              controller: _narrowScroll,
              slivers: [...info, ...streams],
            ),
          );
        }
        final paneWidth = (constraints.maxWidth * 0.38).clamp(320.0, 480.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: CustomScrollView(slivers: info)),
            const VerticalDivider(width: 1),
            SizedBox(
              width: paneWidth,
              child: CustomScrollView(
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
    //
    // Back comes down a ladder here the way it does in the player: the
    // open row of sources is put away first, and only a press with
    // nothing left to put away leaves the screen.
    return PopScope(
      canPop: !_openSourceRowDrawn,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          setState(() {
            _reopenSuppressed = _openSourceGroup;
            _openSourceGroup = null;
          });
        }
      },
      child: Scaffold(
        body: TvBackdrop(
          background: meta.background,
          poster: meta.poster,
          child: SafeArea(child: body),
        ),
      ),
    );
  }

  /// Hero, facts and (for a series) the season selector and episode list.
  ///
  /// On a television the hero is gone: [TvBackdrop] is already drawing the
  /// artwork across the whole panel, so a second copy of it inside a
  /// collapsing app bar would be the same picture twice. What is left of
  /// the bar is the way back and the way to the downloads list, floating
  /// over the backdrop.
  ///
  /// The episodes are a [TvEpisodeRow] there and a [SliverList] of
  /// [_EpisodeTile]s everywhere else. The two carry the same things about
  /// an episode and are otherwise unrelated shapes, which is why this is a
  /// branch rather than one list laid out two ways.
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
    _shownVideoId = _selectedVideoId(state);
    final now = DateTime.now().toUtc();
    return [
      SliverAppBar(
        pinned: !isTv,
        expandedHeight: isTv ? null : (isWide ? 300 : 220),
        backgroundColor: isTv ? Colors.transparent : null,
        scrolledUnderElevation: isTv ? 0 : null,
        // The way out, and it leaves rather than going through
        // `Navigator.maybePop` the way the bar's own [BackButton] does:
        // on a television that press is answered by the ladder below,
        // which puts the open row of sources away and leaves the viewer
        // on the screen they aimed to leave. Back is the key that comes
        // down a ladder, because it is one key for every layer; this is a
        // control the viewer pointed at. Drawn only where there is
        // something to go back to, as the implied one is, so it is never
        // an arrow that does nothing.
        leading: Navigator.of(context).canPop()
            ? BackButton(onPressed: () => Navigator.of(context).pop())
            : null,
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
        child: isTv
            ? TvLadderRow(
                level: _ladderInfo,
                child: TvMetaHeader(
                  meta: meta,
                  isInLibrary: state.isInLibrary,
                  downloads: _downloads?.ofMeta(widget.id) ?? const [],
                  onToggleLibrary: () => _toggleLibrary(state, meta),
                ),
              )
            : _MetaHeader(
                meta: meta,
                isWide: isWide,
                isInLibrary: state.isInLibrary,
                downloads: _downloads?.ofMeta(widget.id) ?? const [],
                onGenre: _openGenre,
                onToggleLibrary: () => _toggleLibrary(state, meta),
              ),
      ),
      if (state.hasVideos) ...[
        if (isTv)
          // The season and its episodes are one rung: picking a season is
          // picking which episodes are under it, and a viewer looking for
          // an episode wants both or neither. Its header says which season
          // and how many, which is the whole of what a shut rung owes.
          SliverToBoxAdapter(
            child: TvLadderRung(
              level: _ladderEpisodesHeader,
              label: kEpisodesLabel,
              summary: _episodesSummary(season, episodes.length),
              open: _shownRung == _DetailsRung.episodes,
              onSelect: () => _selectRung(_DetailsRung.episodes),
              children: [
                if (seasons.length > 1 && season != null)
                  TvLadderRow(
                    level: _ladderSeasons,
                    advanceOnSelect: true,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: _SeasonSelector(
                        seasons: seasons,
                        selected: season,
                        onChanged: (season) => setState(() => _season = season),
                      ),
                    ),
                  ),
                TvLadderRow(
                  level: _ladderEpisodes,
                  advanceOnSelect: true,
                  child: TvEpisodeRow(
                    episodes: episodes,
                    selectedVideoId: _selectedVideoId(state),
                    now: now,
                    // The remote starts here only when this is the rung
                    // the title is for and nothing has taken it yet: a
                    // rung the viewer opens themselves leaves them on the
                    // header they pressed, one press above the row.
                    defaultFocus:
                        _shownRung == _DetailsRung.episodes &&
                        _startedOn == null,
                    isWatched: state.isWatched,
                    resumeProgress: (video) => _resumeProgress(state, video),
                    downloadOf: (video) =>
                        _downloads?.forVideo(widget.id, video.id),
                    onSelect: (video) => _selectVideo(video, reveal: true),
                    onToggleWatched: (video) => _toggleWatched(state, video),
                    onFocus: _focusVideo,
                  ),
                ),
              ],
            ),
          )
        else ...[
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
      ],
      // The same films a television gets, as an ordinary section rather
      // than a rung: this column is what the title *is* -- its name, its
      // description, its episodes -- and what it is like belongs at the
      // end of it. Below the breakpoint that puts it between the episodes
      // and the sources, and on a wide layout at the foot of the left
      // pane, which is the same place in both. It is drawn only where
      // there is no ladder: the television has one.
      if (!isTv && _hasSimilar)
        SliverToBoxAdapter(
          child: SimilarSection(
            titles: _similar,
            onOpen: _openSimilar,
            onAskAgain: () => unawaited(_askSimilarAgain()),
            asking: _reasking,
          ),
        ),
      const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
    ];
  }

  /// What a shut episodes rung says it holds: which season is under it and
  /// how many episodes that is.
  static String _episodesSummary(int? season, int count) => season == null
      ? (count == 1 ? '1 episode' : '$count episodes')
      : 'Season $season · $count';

  /// The streams for the selected video, the meta addon's own first. The
  /// engine lists every addon it asked from the moment of the request (as
  /// `Loading` groups), so the header's small spinner is the only loading
  /// indicator needed once they are in; an empty list means no addon was
  /// asked. Between a tap and that first state there is nothing at all to
  /// list, and the section says so where the tap can see it.
  List<Widget> _streamSlivers(MetaDetailsState state, MetaItem meta) {
    // Nothing is open until the rows below say otherwise: every path out
    // of here that is not [_tvSourceSlivers] draws no row at all.
    _openSourceRowDrawn = false;
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
    final derived = _deriveStreams(
      state,
      isSectioned: isSectioned,
      order: order,
    );
    final profile = derived.profile;
    final empties = derived.empties;
    final failures = derived.failures;
    final sources = derived.sources;
    final sections = derived.sections;
    final grouped = derived.grouped;
    final openSections = _visibleOpenSections(sections);
    final openAddons = _rememberedOpenAddons();
    // The shortcut is the same source as one of the rows below, so it is
    // handed the same merged trackers; nothing else about it changes.
    final lastUsedStream = lastUsed == null
        ? null
        : sources.merged(lastUsed.$2);
    if (isTv && lastUsedStream != null) _takeTheRemoteToTheLastUsed();
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
    if (isTv) {
      return _tvSourceSlivers(
        state,
        isSectioned: isSectioned,
        order: order,
        sections: sections,
        grouped: grouped,
        profile: profile,
        empties: empties,
        failures: failures,
        foundNothing: foundNothing,
        noneYet: noneYet,
        lastUsed: lastUsed,
        lastUsedStream: lastUsedStream,
        sourceCount: sources.length,
        downloads: downloads,
      );
    }
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
            titleOverride: kContinueWithLastSource,
            onTap: () => _play(state, lastUsed!.$1, lastUsedStream),
            downloads: downloads?.forGroup(lastUsed!.$1),
          ),
        ),
      if (isSectioned)
        for (final section in sections)
          _ResolutionSectionSliver(
            section: section,
            expanded: openSections.contains(section.resolution),
            onExpand: () => _toggleSection(section.resolution),
            lastUsed: lastUsed?.$2,
            onPlay: (row) => _play(state, row.group, row.stream),
            downloads: downloads,
          )
      else ...[
        for (final entry in grouped)
          _StreamGroupSliver(
            group: entry.$1,
            name: _addonNameOf(_profileNow, entry.$1),
            rows: entry.$2,
            expanded: openAddons.contains(_addonStorageLabel(entry.$1)),
            onExpand: () => _toggleAddon(entry.$1),
            lastUsed: lastUsed?.$2,
            onPlay: (stream) => _play(state, entry.$1, stream),
            downloads: downloads?.forGroup(entry.$1),
          ),
      ],
      if (empties.isNotEmpty)
        SliverToBoxAdapter(
          child: _EmptyAddonsSummary(
            names: [for (final group in empties) _addonNameOf(profile, group)],
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

  /// The sources list derived from [state]: which groups answered with
  /// nothing and which failed, the source index every layout collapses on,
  /// and the sectioned and the grouped rows -- computed once per distinct
  /// set of inputs and kept ([_derived]).
  ///
  /// Deriving is a handful of regexes per stream ([StreamFacts.of]), a sort
  /// and a sectioning: a few milliseconds for three addons' worth of
  /// streams on a desktop, several times that on the box this runs on. It
  /// used to run on every build, and this screen is rebuilt by things that
  /// change none of its inputs -- a download's progress tick once a second
  /// for as long as anything is downloading, while the screen sits under
  /// the player. The inputs are the field's state (one object per pull),
  /// the `ctx` behind the profile (the same) and the two layout
  /// preferences; what else a build reads -- the open sections, the pins
  /// in flight, the last-used source's merged trackers -- is cheap and
  /// stays in [_streamSlivers].
  _StreamDerivation _deriveStreams(
    MetaDetailsState state, {
    required bool isSectioned,
    required StreamOrder order,
  }) {
    final ctx = _ctx?.value;
    final derived = _derived;
    if (derived != null &&
        derived.isFor(state, ctx, isSectioned: isSectioned, order: order)) {
      return derived;
    }
    MetaDetailsScreen.debugStreamDerivations++;
    final profile = ctx == null ? null : ProfileState.fromCtx(ctx);
    final groups = state.allStreamGroups;
    // An addon that answered with an error has nothing to list, so it is
    // pulled out of the run of groups and collected below the streams
    // instead: several dead addons at once are one row there, not a wall
    // of them above the streams that do work.
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
                    // Read, the same as the sectioned layout reads. This
                    // list does not *rank* by what is in a stream -- it
                    // keeps each addon's own order -- and it was given no
                    // facts at all for that reason, which is why the two
                    // layouts drew different things from different
                    // sources and drifted apart. The television already
                    // paid for this read per card ([_tvSource]); paying
                    // for it once here is what makes one row look the
                    // same whichever way the list is grouped.
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
                  sources,
                  (_) => _addonNameOf(profile, group),
                ),
              ),
          ];
    return _derived = _StreamDerivation(
      state: state,
      ctx: ctx,
      isSectioned: isSectioned,
      order: order,
      profile: profile,
      empties: empties,
      failures: failures,
      sources: sources,
      sections: sections,
      grouped: grouped,
    );
  }

  /// The sources of the selected video as the two rows a television picks
  /// from ([TvSourceRows]), in place of the column of collapsible sections
  /// a phone and a desktop scroll.
  ///
  /// The groups are the same two the preference already chooses between --
  /// a card per resolution rung, or a card per addon -- so nothing new is
  /// stored and the order chips in the header still order inside one. What
  /// is not shared is *which* group is open: the phone remembers a set of
  /// resolutions across restarts, and this is one row at a time that Back
  /// puts away (see [_openSourceGroup]).
  ///
  /// Everything around the sources stays where it was, below them: the
  /// addons that had nothing, the ones that failed, and the notice when
  /// nobody had anything.
  List<Widget> _tvSourceSlivers(
    MetaDetailsState state, {
    required bool isSectioned,
    required StreamOrder order,
    required List<StreamSection<_SourceRow>> sections,
    required List<(StreamGroup, List<_SourceRow>)> grouped,
    required ProfileState? profile,
    required List<StreamGroup> empties,
    required List<AddonFailure> failures,
    required bool foundNothing,
    required bool noneYet,
    required (StreamGroup, StreamInfo)? lastUsed,
    required StreamInfo? lastUsedStream,
    required int sourceCount,
    required _StreamDownloads? downloads,
  }) {
    TvSource source(_SourceRow row) => _tvSource(
      state,
      row,
      isSectioned: isSectioned,
      lastUsed: lastUsed?.$2,
      downloads: downloads,
    );
    final groups = <TvSourceGroup>[
      if (isSectioned)
        for (final section in sections)
          (
            label: section.label,
            count: '${section.rows.length}',
            icon: null,
            sources: [for (final row in section.rows) source(row)],
          )
      else
        for (final (group, rows) in grouped)
          (
            label: _addonNameOf(profile, group),
            // A group with nothing in it is here only while its answer is
            // still coming: one that settled on no streams was taken out
            // of the list above. A pill has no room to say so in words,
            // so it says nothing rather than a zero that reads as "none".
            count: rows.isEmpty && group.isLoading ? null : '${rows.length}',
            icon: null,
            sources: [for (final row in rows) source(row)],
          ),
    ];
    // Every addon is still answering and there is not a pill to draw yet.
    // [TvSourceRows] draws nothing for no groups, which would leave an
    // open sources rung with nothing under its header at all; the row the
    // pills will fill gets a spinner in its middle instead.
    final waiting = groups.isEmpty && state.isLoadingStreams;
    final accounting = _tvAccounting(
      profile: profile,
      empties: empties,
      failures: failures,
      foundNothing: foundNothing,
      isEpisode: state.hasVideos,
    );
    // A rung with nothing behind its header is not drawn at all, so the
    // walk steps over it rather than stopping on a line that opens
    // nothing.
    final hasSources = groups.isNotEmpty || waiting || noneYet;
    final rung = _shownRung = _rungToOpen(
      state,
      hasLastUsed: lastUsedStream != null,
      hasSources: hasSources,
      hasAddons: accounting != null,
    );
    final sourcesOpen = rung == _DetailsRung.sources;
    // What Back has to put away, which is the row [TvSourceRows] will
    // actually draw rather than the label on its own (see
    // [_openSourceRowDrawn]) -- and only while the rung holding that row
    // is the one that is open, or a shut rung would swallow the press.
    _openSourceRowDrawn =
        sourcesOpen && groups.any((g) => g.label == _openSourceGroup);
    return [
      // The shortcut is a rung of its own above the sources, and the one
      // the screen opens for a title that has been played: it is the
      // source the viewer is most likely to want, which is why it is drawn
      // at all.
      //
      // Keyed, and so is the rung below it, because this one *appears*:
      // the engine writes the last-used source down while the player is
      // up, so the first thing a title is ever played from comes back to
      // a sliver list one longer than it left. Unkeyed, the rungs below
      // would be matched against this one's adapter, torn down and
      // rebuilt -- taking the focus node the remote was on with them, and
      // then this card, freshly built and asking for focus, would answer
      // the D-pad instead of the card the viewer left.
      if (lastUsedStream != null)
        SliverToBoxAdapter(
          key: const ValueKey('tv-last-used'),
          child: TvLadderRung(
            level: _ladderLastUsedHeader,
            label: kContinueWatchingLabel,
            // Which release it would carry on with: the one thing that
            // tells a viewer whether to press select or go and pick
            // another, and all a shut rung has room for.
            summary: releaseNameOf(
              lastUsedStream,
              addonName: _addonNameOf(profile, lastUsed!.$1),
            ),
            open: rung == _DetailsRung.continueWatching,
            onSelect: () => _selectRung(_DetailsRung.continueWatching),
            children: [
              TvLadderRow(
                level: _ladderLastUsed,
                child: TvSourceRow(
                  defaultFocus: _startedOn == null,
                  focusNode: _lastUsedNode,
                  sources: [
                    _tvLastUsed(state, lastUsed.$1, lastUsedStream, downloads),
                  ],
                ),
              ),
            ],
          ),
        ),
      if (hasSources)
        SliverToBoxAdapter(
          key: const ValueKey('tv-source-rows'),
          child: TvLadderRung(
            level: _ladderSourcesHeader,
            label: kSourcesLabel,
            // Nothing to count yet and addons still out: say what is
            // being waited for rather than "0 from 0 addons".
            summary: sourceCount == 0 && state.isLoadingStreams
                ? kLookingForStreams
                : _sourcesSummary(state, sources: sourceCount),
            // The heading's own small spinner had nowhere left to go once
            // the heading became this line, and a line that says how many
            // sources there are while more are still arriving has to say
            // that too.
            trailing: !waiting && state.isLoadingStreams
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            open: sourcesOpen,
            onSelect: () => _selectRung(_DetailsRung.sources),
            children: [
              _StreamsHeader(
                key: _streamsKey,
                state: state,
                sectioned: isSectioned,
                onSectionedChanged: _setStreamsSectioned,
                order: order,
                onOrderChanged: _setStreamsOrder,
                // The rung header above carries it now.
                heading: false,
                withSpinner: false,
                layoutLevel: _ladderStreamControls,
                orderLevel: _ladderStreamOrder,
              ),
              if (waiting)
                SizedBox(
                  key: const ValueKey('tv-sources-waiting'),
                  height: TvSourceRows.sourceRowHeight(context),
                  // The spinner alone: the rung's own header line is
                  // saying what it is waiting for, and saying it twice on
                  // one screen reads as two different waits.
                  child: const Center(child: CircularProgressIndicator()),
                ),
              if (noneYet)
                const ListTile(
                  leading: Icon(Icons.touch_app_outlined),
                  title: Text('Pick an episode to see its streams'),
                ),
              TvSourceRows(
                groups: groups,
                openLabel: _openSourceGroup,
                onOpen: (label) => setState(() {
                  _openSourceGroup = label;
                  _reopenSuppressed = null;
                }),
                onFocusGroup: _focusSourceGroup,
                groupLevel: _ladderGroups,
                sourceLevel: _ladderSources,
                // Whether the first pill is the screen's starting
                // place, and -- when the viewer opens this rung
                // themselves later -- what makes it put a row of sources
                // out rather than a row of pills with nothing under
                // them. The autofocus half of that is dropped by Flutter
                // when the header already holds the remote, which is the
                // only way of arriving here with something focused.
                defaultFocus: lastUsedStream == null,
              ),
            ],
          ),
        ),
      if (_hasSimilar)
        SliverToBoxAdapter(
          key: const ValueKey('tv-more-like-this'),
          child: _tvSimilarRung(open: rung == _DetailsRung.moreLikeThis),
        ),
      if (accounting != null)
        SliverToBoxAdapter(
          key: const ValueKey('tv-source-accounting'),
          child: TvLadderRung(
            level: _ladderAddonsHeader,
            label: accounting.label,
            summary: accounting.summary,
            open: rung == _DetailsRung.addons,
            onSelect: () => _selectRung(_DetailsRung.addons),
            children: [
              TvLadderRow(
                level: _ladderAddons,
                // The last rung standing is where the remote starts: a
                // fresh profile whose addons all had nothing opens on
                // this, and a screen with nothing focused is a dead
                // D-pad.
                child: TvSourceRow(
                  defaultFocus: _startedOn == null,
                  sources: accounting.sources,
                ),
              ),
            ],
          ),
        ),
      const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
    ];
  }

  /// What a model says this title is like, as a rung below the sources.
  ///
  /// **Everything here is about a row that arrives late.** The answer
  /// takes three seconds when it comes at all, by which time the viewer
  /// has read the screen and moved the remote, and this screen has been
  /// broken twice already by something appearing under a viewer who was
  /// using it (see [_takeTheRemoteToTheLastUsed] and
  /// [FocusableTile._autofocus]). Three things keep it still, and none of
  /// them is optional:
  ///
  ///  * **The header is there from the first frame.** Whether there is a
  ///    rung at all is decided by whether a key is configured, which is
  ///    known before the title is drawn -- so the line appears with the
  ///    rest of the ladder and says it is looking, and the answer landing
  ///    changes the words on it and nothing else. A rung that appeared
  ///    when the answer did would push everything below it down the panel
  ///    at a moment nobody chose.
  ///  * **Nothing in it asks for the remote.** Every other rung hands its
  ///    row a `defaultFocus` for the arrival case; this one never does,
  ///    at any point in its life. The remote gets here by being walked
  ///    here.
  ///  * **The row is the same height empty as full** ([SimilarTitlesRow]),
  ///    so even a viewer standing inside the open rung when the answer
  ///    lands sees posters replace a spinner and nothing move.
  ///
  /// And when the answer is nothing -- a model with nothing to say, or a
  /// row the guard emptied -- the rung goes away rather than standing
  /// there as a header over an empty strip.
  ///
  /// The way to ask again is the last card *of the row* rather than
  /// anything on this header, which is both where the D-pad already goes
  /// and the one place it cannot be what the rung focuses first; see the
  /// card ([SimilarTitlesRow.onAskAgain]).
  Widget _tvSimilarRung({required bool open}) {
    final titles = _similar;
    return TvLadderRung(
      level: _ladderSimilarHeader,
      label: kMoreLikeThisLabel,
      // Titles rather than films: the guard resolves a suggestion against
      // both catalogues, and a series that is like this film is a right
      // answer rather than a mistake to paper over in the summary.
      summary: titles == null
          ? kLookingForSimilar
          : (titles.length == 1 ? '1 title' : '${titles.length} titles'),
      // No spinner on the line, unlike the sources' header: this is not
      // what the viewer is waiting for. They came for something to watch,
      // and a second thing turning on the panel while the sources fill is
      // a race between two waits when only one of them is theirs. The
      // words say it, once.
      open: open,
      onSelect: () => _selectRung(_DetailsRung.moreLikeThis),
      children: [
        TvLadderRow(
          level: _ladderSimilar,
          child: SimilarTitlesRow(
            titles: titles,
            onOpen: _openSimilar,
            onAskAgain: () => unawaited(_askSimilarAgain()),
            asking: _reasking,
          ),
        ),
      ],
    );
  }

  /// A suggestion was chosen: this screen again, for that title.
  ///
  /// Pushed rather than replaced, the way the board's tiles open a title,
  /// so Back comes back to the film the suggestion was about. Two of these
  /// screens on one field is what [SharedFieldScreen] is for.
  void _openSimilar(MetaItemPreview item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MetaDetailsScreen(type: item.type, id: item.id),
      ),
    );
  }

  /// What a shut sources rung says it holds: how many sources there are
  /// between every addon that answered, and how many addons that was.
  ///
  /// The count is of *sources* and not of listings, which is what the
  /// grouped layout would otherwise say: one release two addons both
  /// offered is one thing a viewer can watch, and the pills below it say
  /// the same by both wearing it.
  String _sourcesSummary(MetaDetailsState state, {required int sources}) {
    final addons = state.allStreamGroups
        .where((group) => group.streams.isNotEmpty)
        .length;
    final from = addons == 1 ? '1 addon' : '$addons addons';
    return '$sources from $from';
  }

  /// What the addons did other than answer with streams, as a rung of its
  /// own at the foot of the ladder; null when there is nothing to account
  /// for.
  ///
  /// A rung and not one more pill among the resolutions, which is what it
  /// was: it is not a group of sources, and its one line -- how many
  /// failed, how many had nothing -- is exactly the shape a rung header
  /// has and nothing a 36 dp pill could carry. The row underneath carries
  /// the names, what each dead addon said, and the two things worth doing
  /// about one: opening its details, whose manifest fetch is the
  /// reachability test (select), and uninstalling it (a hold, since a
  /// button drawn inside a card cannot be reached by a remote).
  ///
  /// Nobody having anything at all is not one more line here but the
  /// rung's own name, because on a fresh profile it is the answer to the
  /// screen rather than a footnote to it.
  ({String label, String summary, List<TvSource> sources})? _tvAccounting({
    required ProfileState? profile,
    required List<StreamGroup> empties,
    required List<AddonFailure> failures,
    required bool foundNothing,
    required bool isEpisode,
  }) {
    if (empties.isEmpty && failures.isEmpty && !foundNothing) return null;
    final locked = profile?.addonsLocked ?? false;
    final quiet = [
      for (final group in empties)
        (name: _addonNameOf(profile, group), transportUrl: group.request.base),
    ];
    final names = [for (final addon in quiet) addon.name];
    return (
      label: foundNothing
          ? _NoStreamsNotice.titleOf(isEpisode)
          : kSourceAccountingLabel,
      summary: [
        if (failures.isNotEmpty)
          FailedAddonsSection.addonsLabel(failures.length),
        if (names.isNotEmpty)
          _EmptyAddonsSummary.summaryLabel(names.length, isEpisode: isEpisode),
        if (failures.isEmpty && names.isEmpty) kNothingCameBack,
      ].join(' · '),
      sources: [
        if (foundNothing)
          (
            icon: Icons.extension_outlined,
            title: _NoStreamsNotice.addonsLabel,
            facts: [_NoStreamsNotice.explanation],
            details: const [],
            highlighted: false,
            download: null,
            downloading: false,
            onSelect: _openAddons,
            onHold: null,
          ),
        for (final failure in failures)
          (
            icon: Icons.cloud_off_outlined,
            title: failure.name,
            facts: [failure.message],
            details: const [],
            highlighted: false,
            download: null,
            downloading: false,
            onSelect: () => openAddonDetails(context, failure.transportUrl),
            onHold: failure.isRemovable && !locked
                ? () =>
                      confirmAndUninstallAddon(context, _client, failure.addon!)
                : null,
          ),
        // One card each rather than one card listing them all: a joined
        // line is ellipsized at the fourth name in a card 300 wide, and
        // there is no press on a television that unfolds it -- which is
        // how the phone's summary shows the same names. Each takes a
        // press to its own details, the same one a failed addon's card
        // takes, which is also what lets the remote walk the row far
        // enough to read the last of them.
        for (final addon in quiet)
          (
            icon: Icons.inbox_outlined,
            title: addon.name,
            facts: const [kAddonHadNothing],
            details: const [],
            highlighted: false,
            download: null,
            downloading: false,
            onSelect: () => openAddonDetails(context, addon.transportUrl),
            onHold: null,
          ),
      ],
    );
  }

  /// One row of the sources list as a television card draws it: the
  /// release it is, and under it the one line of facts a 96 dp card has
  /// room for.
  ///
  /// **The release leads.** The engine has no field for it, and what the
  /// list showed instead was the stream's `name` -- which for Torrentio is
  /// the addon and the quality, so four cards read "Torrentio" four times
  /// and the thing that actually tells them apart was nowhere on the
  /// screen. [releaseNameOf] is where it comes from now.
  ///
  /// **The facts line says what the pill above it does not.** The pills
  /// are the resolutions in the sectioned layout and the addons in the
  /// grouped one, so exactly one of those two is worth repeating on the
  /// card, and the other would be the same word on every card in the row.
  /// The rest -- the seeders, the size -- is on every card either way.
  ///
  /// What no longer fits is the release tags and the addons that offered
  /// the same source: another addon having it is a `+1` after the addon's
  /// name, which is the fact without the sentence. Both are carried whole
  /// in [TvSource.details] instead, which the strip under the row draws
  /// for the one card the remote is on ([TvSourceDetailStrip]).
  ///
  /// A source the player cannot open leads the line with which kind it is
  /// instead of taking a press, so it is not a focus stop and the remote
  /// steps over it -- the disabled row, in the shape a card has.
  TvSource _tvSource(
    MetaDetailsState state,
    _SourceRow row, {
    required bool isSectioned,
    required StreamInfo? lastUsed,
    required _StreamDownloads? downloads,
  }) {
    final stream = row.stream;
    final facts = row.facts;
    final hints = facts == null ? StreamHints.of(stream) : null;
    final bound = downloads?.forGroup(row.group);
    final addon = facts?.addonName ?? _addonNameOf(_profileNow, row.group);
    final others = row.alsoFrom.length;
    // The grouped layout ranks inside one addon's own answer and so reads
    // nothing out of the streams; the strip under the row wants the tags
    // either way, and reading them twice is cheaper than carrying a second
    // list through the derivation for the sake of one card.
    final read = facts ?? StreamFacts.of(stream, addonName: addon);
    return (
      icon: _StreamTile._iconFor(stream.kind),
      title: releaseNameOf(stream, addonName: addon),
      facts: [
        if (!stream.isPlayable) stream.kind.label,
        if (facts != null) ...[
          ?facts.seedersLabel,
          ?facts.sizeLabel,
        ] else ...[
          ?hints!.resolution,
          if (hints.seeders != null) '${hints.seeders} seeders',
          ?hints.size,
        ],
        // The pill says the other one of these two on every card below it.
        if (isSectioned)
          others == 0 ? addon : '$addon +$others'
        else if (facts?.resolutionLabel != null)
          facts!.resolutionLabel!,
      ],
      details: [
        // What kind of source it is, which a playable card says with an
        // icon and nothing else -- an icon is a glyph a viewer has to
        // have learnt. One that is not playable already leads its facts
        // line with the word, and saying it twice on one panel reads as
        // two different things.
        if (stream.isPlayable) stream.kind.label,
        // The release tags, which are what went when the card was cut to
        // two lines of name over one of facts.
        ...read.tags,
        // The `+1` on the card's facts line, spelled out: which addon.
        if (row.alsoFrom.isNotEmpty) 'also from ${row.alsoFrom.join(', ')}',
      ],
      highlighted: lastUsed != null && stream.isSameSource(lastUsed),
      download: bound?.entryOf(stream),
      downloading: bound?.isPending(stream) ?? false,
      onSelect: stream.isPlayable
          ? () => _play(state, row.group, stream)
          : null,
      onHold: bound?.remoteAction(stream),
    );
  }

  /// The profile as the last derivation read it, for the places that want
  /// an addon's name outside one.
  ProfileState? get _profileNow => _derived?.profile;

  /// The last-used source as its own card: the same shortcut the vertical
  /// list draws above the sections, saying what it is on the first line
  /// and which release it is on the second.
  TvSource _tvLastUsed(
    MetaDetailsState state,
    StreamGroup group,
    StreamInfo stream,
    _StreamDownloads? downloads,
  ) {
    final bound = downloads?.forGroup(group);
    return (
      icon: Icons.history,
      title: kContinueWithLastSource,
      facts: [
        releaseNameOf(stream, addonName: _addonNameOf(_profileNow, group)),
      ],
      // A rung of one card with nothing under it: the strip is the
      // sources row's, and this card's whole line is the release already.
      details: const [],
      highlighted: true,
      download: bound?.entryOf(stream),
      downloading: bound?.isPending(stream) ?? false,
      onSelect: () => _play(state, group, stream),
      onHold: bound?.remoteAction(stream),
    );
  }

  /// Puts the sources list in one layout or the other, for everything the
  /// app shows from now on: the preference is global, not this title's.
  ///
  /// The groups on a television are the layout's own, so the row that was
  /// open is about a grouping that no longer exists.
  void _setStreamsSectioned(bool value) {
    _openSourceGroup = null;
    _prefs?.setStreamsSectioned(value);
  }

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

  /// Every addon group the viewer has ever opened, anywhere, straight out
  /// of [AppPrefs.openStreamAddons]. Empty both when nothing has ever been
  /// chosen and when the viewer shut the last one on purpose -- both mean
  /// every group closed, which is what a fresh install shows.
  ///
  /// Each group asks this set for *its own* label, which is the rule
  /// [_visibleOpenSections] spells out for the resolutions: a remembered
  /// addon this title has no sources from opens nothing, and is never
  /// substituted with some other addon's group.
  Set<String> _rememberedOpenAddons() =>
      _prefs?.openStreamAddons ?? const <String>{};

  /// Opens or closes one addon group, on the *full* remembered set (every
  /// addon ever opened on any title), not just what this title shows open:
  /// otherwise closing a group here could silently drop an addon another
  /// title still remembers, one that had nothing for this title in the
  /// first place.
  void _toggleAddon(StreamGroup group) {
    final label = _addonStorageLabel(group);
    final full = _rememberedOpenAddons();
    _prefs?.setOpenStreamAddons({
      for (final addon in full)
        if (addon != label) addon,
      if (!full.contains(label)) label,
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

/// The IMDb rating, and the way to the page it came from.
///
/// A link only when the addon sent the rating with an address
/// ([MetaItem.imdbLink]); without one the rating is the plain line it has
/// always been, since the address is never built here out of an id.
///
/// The television has none of this. This is the phone's and the desktop's
/// header ([TvMetaHeader] is the other one), which is where a browser can
/// be relied on: a set-top box usually has nothing to hand the address to,
/// and the remote would gain a stop whose whole answer is "could not open".
class _ImdbRating extends StatelessWidget {
  const _ImdbRating({required this.rating, this.url});

  final String rating;

  /// The title's page on IMDb; null leaves the rating unclickable.
  final String? url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = this.url;
    final line = Row(
      mainAxisSize: MainAxisSize.min,
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
        if (url != null) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.open_in_new,
            size: 13,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ],
    );
    if (url == null) return line;
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        // Hugging the words rather than the column's width: a tap lands
        // where the thing it opens is drawn.
        onTap: () => openInBrowser(context, url),
        borderRadius: BorderRadius.circular(6),
        child: Semantics(
          link: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: line,
          ),
        ),
      ),
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

  static const String addTooltip = TvMetaHeader.addTooltip;
  static const String removeTooltip = TvMetaHeader.removeTooltip;

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
          _ImdbRating(rating: rating, url: meta.imdbUrl),
        ],
        if (genres.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: -8,
            children: [
              // Wrapped for the same reason the filter chips are: the
              // floor fills a chip and cannot outline one. This header is
              // the phone's and the desktop's -- a television gets
              // [TvMetaHeader] instead -- so [FocusMarked] is its child
              // and nothing else here today. It is on every chip in the
              // app all the same, so which chips are marked is something
              // to read rather than to trace.
              for (final genre in genres)
                FocusMarked(
                  borderRadius: FocusMarked.stadium,
                  child: ActionChip(
                    label: Text(genre.name),
                    visualDensity: VisualDensity.compact,
                    onPressed: switch (genre.discoverRequest) {
                      null => null,
                      final request => () => onGenre(request),
                    },
                  ),
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
/// - **A pill is as wide as it needs to be**, up to an even share of the
///   row. Two seasons stretched across a television read as two buttons
///   for something else entirely, so the even share is a ceiling now and
///   [_SeasonSelector._maxPillWidth] is the other one; the row is packed
///   at the left like every other row on the screen. What that costs is
///   that directional focus, which prefers whatever overlaps the press
///   horizontally, no longer finds the pills from anywhere along the row
///   below. That is [TvLadder]'s job on this screen and not geometry's:
///   the pills are a rung, and an up press from the episodes reaches them
///   from anywhere along the row.
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

  /// The widest a pill is drawn, however few seasons share the row. Enough
  /// for `Specials` and the padding a chip puts around it.
  static const double _maxPillWidth = 120;

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

  /// One focus node per season, kept for as long as this row is on screen.
  ///
  /// A node per *season* rather than one for "the selected pill": focusing
  /// a pill is what changes the season here, so a node that followed the
  /// selection would be taken off the chip the remote had just landed on
  /// and handed to another, which is focus disappearing mid-press.
  final Map<int, FocusNode> _nodes = {};

  FocusNode _nodeFor(int season) =>
      _nodes.putIfAbsent(season, () => FocusNode(debugLabel: 'season $season'));

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
    for (final node in _nodes.values) {
      node.dispose();
    }
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
              // An even share of the row each as a *minimum*, and never
              // wider than [_SeasonSelector._maxPillWidth]: a series with
              // two seasons draws two ordinary pills at the left rather
              // than two halves of a television, and one with thirty keeps
              // them at their own width and scrolls.
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
              final share = even > 0
                  ? (even < _SeasonSelector._maxPillWidth
                        ? even
                        : _SeasonSelector._maxPillWidth)
                  : 0.0;
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
                          focusNode: _nodeFor(season),
                          // The remote landing on a pill is the viewer
                          // asking to see that season: the episodes below
                          // follow the highlight, and select is left to
                          // mean the press that goes down into them.
                          onFocused: () => widget.onChanged(season),
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
    final date = episodeDateLabel(video);
    final episode = video.episode;
    final title = video.title.isEmpty && episode != null
        ? 'Episode $episode'
        : video.title;
    final tile = ListTile(
      selected: isSelected,
      enabled: isReleased,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: EpisodeThumbnail(video: video),
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

  /// Why the list is empty, in the one sentence that is worth saying: a
  /// fresh install has no torrent addon and this is what that looks like.
  static const String explanation =
      'None of your sources had anything to play. xtremio comes with no '
      'torrent addon, so add one and its streams show up here.';

  /// What came up empty: an episode of a series, or the title.
  static String titleOf(bool isEpisode) =>
      isEpisode ? 'No streams for this episode' : 'No streams for this title';

  String get title => titleOf(isEpisode);

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
                    Text(explanation, style: theme.textTheme.bodySmall),
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

/// The shortcut to the source this title was last played from, above the
/// sections on a phone and its own card on a television.
const String kContinueWithLastSource = 'Continue with last source';

/// The rung at the foot of a television's ladder: what the addons did
/// other than answer with streams.
const String kSourceAccountingLabel = 'Addons';

/// What the rung holding the last-used source is called when it is shut.
const String kContinueWatchingLabel = 'Continue watching';

/// What the rung holding the sources is called when it is shut. "Sources"
/// and not "Streams": a television's rung is a row of releases to pick
/// from, and the word the rest of this screen's TV code uses for one.
const String kSourcesLabel = 'Sources';

/// What the rung holding the season and its episodes is called.
const String kEpisodesLabel = 'Episodes';

/// What that card says when every addon answered and none of them said
/// anything worth counting.
const String kNothingCameBack = 'Nothing came back';

/// What one card of that row says under an addon that answered with
/// nothing. The count and the wording that goes with it -- for this
/// episode, for this title -- are on the card that opens the row.
const String kAddonHadNothing = 'Had nothing to offer';

/// What each of the header's two layout chips reads. The selected one is
/// the layout on screen, which is why both are worded as states rather
/// than as actions: a chip that says what it would do reads as a lie the
/// moment it is the one already chosen.
const String kStreamsSectionedLabel = 'Sectioned by resolution';
const String kStreamsGroupedLabel = 'Grouped by addon';

/// The key on one resolution section's header.
///
/// A test (and anything else looking for a heading) has to be able to say
/// *which* section it means, and the label alone cannot: a 1080p row badges
/// itself `1080p` too, so the text is on the heading and on every row under
/// it.
Key streamSectionKey(StreamResolution? resolution) =>
    ValueKey('streams-section-${resolution?.label ?? 'unknown'}');

/// The label [AppPrefs.openStreamAddons] stores one addon group under: the
/// addon's transport URL, which is the identity the profile, the
/// failed-addon rows and a pin all key on already.
///
/// Not the heading: that is a name, and a name is neither unique (two
/// addons may call themselves the same thing) nor stable (a manifest
/// renames itself and the group a viewer opened would come back shut). The
/// streams a *meta* addon attached to the video are a group of their own,
/// under a heading of their own ("From ..."), and get a label of their own
/// -- the same addon can answer both as the meta addon and as a stream
/// addon, and the two groups open and close separately.
String _addonStorageLabel(StreamGroup group) =>
    group.isFromMeta ? 'meta:${group.request.base}' : group.request.base;

/// The key on one addon group's header, where [storageLabel] is what
/// [_addonStorageLabel] made of the group -- the addon's transport URL.
///
/// By the stored label and not by the heading, for the reason that label
/// exists: a heading is a name, two addons may share one, and a test that
/// tapped a name would be tapping whichever group came first.
Key streamAddonKey(String storageLabel) =>
    ValueKey('streams-addon-$storageLabel');

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
    this.withSpinner = true,
    this.heading = true,
    this.layoutLevel,
    this.orderLevel,
  });

  /// Whether the heading draws its own title and the line about which
  /// episode it is.
  ///
  /// False on a television, where the sources are a rung of a collapsing
  /// ladder and the rung's header line already says what this is and how
  /// much of it there is. What is left here is the chips, which are the
  /// two choices about the list rather than a heading over it.
  final bool heading;

  /// Which rungs of the screen's [TvLadder] the heading's two chip rows
  /// are, or null off a television and in the layouts that have no ladder.
  ///
  /// Two rungs and not one: they are drawn one above the other, so a
  /// single rung would mean a press down from the layout chips left the
  /// heading entirely and neither row could be reached from the other.
  final int? layoutLevel;
  final int? orderLevel;

  /// Puts one line of the heading on a rung, when there is a ladder.
  ///
  /// Select on a chip picks it and then moves down, as it does on the
  /// rows where landing already chooses: a viewer who has chosen how the
  /// sources are cut or ordered is on the way to the sources.
  static Widget _rung(int? level, Widget child) => level == null
      ? child
      : TvLadderRow(level: level, advanceOnSelect: true, child: child);

  final MetaDetailsState state;

  /// Whether the heading wears its small spinner while addons are still
  /// answering. False when the list below is drawing a larger one of its
  /// own, so the screen never spins in two places at once.
  final bool withSpinner;

  /// Whether the list below is the one cut into resolution sections,
  /// rather than one section per addon.
  final bool sectioned;

  /// Picks the layout; null draws no layout chips at all.
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
          if (heading)
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
                      if (subtitle != null)
                        Text(subtitle, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                if (withSpinner && (isLoading || state.isLoadingStreams))
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          // How the list is cut, as a choice rather than as a switch: two
          // chips reading the two layouts, the selected one being what is
          // on screen. Above the order chips because it is the larger
          // decision of the two -- an order only exists inside the
          // sectioned layout -- and packed left like every other row here.
          if (onSectionedChanged != null)
            _rung(
              layoutLevel,
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: FilterChips<bool>(
                  options: [
                    FilterOption(
                      label: kStreamsSectionedLabel,
                      selected: sectioned,
                      request: true,
                    ),
                    FilterOption(
                      label: kStreamsGroupedLabel,
                      selected: !sectioned,
                      request: false,
                    ),
                  ],
                  onSelect: onSectionedChanged!,
                ),
              ),
            ),
          if (sectioned && onOrderChanged != null)
            _rung(
              orderLevel,
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

/// The sources list as derived from one state of the field, one `ctx` and
/// the two layout preferences: everything `_streamSlivers` needs that costs
/// anything to compute, with the inputs it was computed from, so a build
/// whose inputs are the same objects reuses it (see `_deriveStreams`).
final class _StreamDerivation {
  const _StreamDerivation({
    required this.state,
    required this.ctx,
    required this.isSectioned,
    required this.order,
    required this.profile,
    required this.empties,
    required this.failures,
    required this.sources,
    required this.sections,
    required this.grouped,
  });

  final MetaDetailsState state;
  final Map<String, dynamic>? ctx;
  final bool isSectioned;
  final StreamOrder order;

  /// The profile behind [ctx]; null until its first pull comes back.
  final ProfileState? profile;

  /// The groups that answered with nothing, and the addons that failed.
  final List<StreamGroup> empties;
  final List<AddonFailure> failures;

  /// What the addons agree is one source, and its merged trackers.
  final StreamSourceIndex sources;

  /// The rows of the sectioned layout, and of the grouped one; whichever
  /// [isSectioned] did not choose is empty.
  final List<StreamSection<_SourceRow>> sections;
  final List<(StreamGroup, List<_SourceRow>)> grouped;

  /// Whether this was derived from exactly these inputs. The state and the
  /// `ctx` map are one object per pull ([SharedFieldScreen.ownState],
  /// [CoreFieldNotifier.value]), so identity says whether anything landed.
  bool isFor(
    MetaDetailsState state,
    Map<String, dynamic>? ctx, {
    required bool isSectioned,
    required StreamOrder order,
  }) =>
      identical(this.state, state) &&
      identical(this.ctx, ctx) &&
      this.isSectioned == isSectioned &&
      this.order == order;
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

  /// What a hold on the source [stream] is drawn on does about the copy on
  /// the device, for a remote that cannot press the button.
  ///
  /// Directional traversal skips a node inside the focused one's rect, and
  /// the button is inside the row or the card the remote activates as a
  /// whole, so on a television it can be looked at and never reached. A
  /// long press -- hold select, or the remote's menu key -- is the "more
  /// options" gesture everywhere else in the app, and here there is
  /// exactly one option: whatever the button beside the play arrow would
  /// do. Null while there is nothing to do (a stream the server cannot
  /// keep, a pin in flight, a download still arriving), which leaves a
  /// hold meaning what it meant before -- a tap on release.
  VoidCallback? remoteAction(StreamInfo stream) {
    if (isPending(stream)) return null;
    final entry = entryOf(stream);
    if (entry == null) return starter(stream);
    return switch (entry.state) {
      DownloadState.complete => () => onDelete(entry),
      DownloadState.error || DownloadState.gone => starter(stream),
      _ => null,
    };
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
    this.downloads,
  });

  final StreamSection<_SourceRow> section;
  final bool expanded;
  final VoidCallback onExpand;

  /// The stream pinned as "Continue with last source", highlighted here too.
  final StreamInfo? lastUsed;
  final ValueChanged<_SourceRow> onPlay;

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
                downloads: downloads?.forGroup(row.group),
              );
            },
          ),
      ],
    );
  }
}

/// One addon's answer: a header that says whose it is and how much is in
/// it, the streams under it when it is open, and a spinner while they are
/// still on their way.
///
/// Collapsible for the reason the resolution sections are: with several
/// addons installed the open groups ran one after another for screens, and
/// what a viewer wanted was the one addon they trust. A closed header
/// still says how many streams are folded away -- not how healthy they
/// are, the way [_ResolutionSectionSliver] does: this list is each addon's
/// own ranking, and a summary of what is inside would be summarising an
/// order the addon chose rather than one this screen did.
///
/// Only groups with something to show reach here. An addon that *failed* is
/// collected into [FailedAddonsSection], and one that answered with
/// nothing into [_EmptyAddonsSummary], both below the streams that did
/// arrive.
class _StreamGroupSliver extends StatelessWidget {
  const _StreamGroupSliver({
    required this.group,
    required this.name,
    required this.rows,
    required this.expanded,
    required this.onExpand,
    required this.lastUsed,
    required this.onPlay,
    this.downloads,
  });

  final StreamGroup group;

  /// What to call the addon: the name out of its own manifest, which is
  /// what it calls itself and what the Addons screen calls it.
  ///
  /// The heading used to be `group.addonLabel`, which is the host of the
  /// manifest URL -- so a list of "Torrentio", "Comet" and "MediaFusion"
  /// read as "torrentio.strem.fun", "comet.elfhosted.com" and
  /// "mediafusion.elfhosted.com": the hosting arrangement rather than the
  /// addon, and three of them sharing a domain look like one thing.
  /// Everything else on this screen already resolved the name and only
  /// the heading did not ([_addonNameOf], which falls back to the host
  /// for an addon the profile has never heard of).
  final String name;

  /// What to list under the heading: the group's streams with this addon's
  /// own repeats collapsed and every one of them carrying the trackers the
  /// other addons named for the same source.
  final List<_SourceRow> rows;

  /// Whether the rows are on screen. Remembered across titles and restarts
  /// in [AppPrefs.openStreamAddons]; with nothing remembered every group is
  /// closed.
  final bool expanded;
  final VoidCallback onExpand;

  /// The stream pinned as "Continue with last source", highlighted here too.
  final StreamInfo? lastUsed;
  final ValueChanged<StreamInfo> onPlay;

  /// The downloads, when there is a client above this screen.
  final _StreamDownloads? downloads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = group.isFromMeta ? 'From $name' : name;
    // Nothing yet, as opposed to nothing at all: a group that settled on
    // no streams is not listed here at all any more, so the label with a
    // spinner under it can only mean the answer is still coming.
    final waiting = rows.isEmpty && group.isLoading;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: ListTile(
            key: streamAddonKey(_addonStorageLabel(group)),
            leading: Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            // A group still answering has nothing folded away yet, so it
            // counts nothing and says so with the spinner below instead.
            subtitle: waiting
                ? null
                : Text(
                    rows.length == 1 ? '1 stream' : '${rows.length} streams',
                  ),
            onTap: onExpand,
          ),
        ),
        // Whatever the memory says: an answer still on its way is not
        // something the viewer closed, and a spinner nobody can see reads
        // as an addon that was never asked.
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
        if (expanded)
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final stream = rows[index].stream;
              final lastUsed = this.lastUsed;
              return _StreamTile(
                stream: stream,
                facts: rows[index].facts,
                headedByAddon: true,
                alsoFrom: rows[index].alsoFrom,
                highlighted: lastUsed != null && stream.isSameSource(lastUsed),
                onTap: stream.isPlayable ? () => onPlay(stream) : null,
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
    this.downloads,
    this.facts,
    this.alsoFrom = const [],
    this.headedByAddon = false,
  });

  final StreamInfo stream;

  /// The other addons that offered this very source, when more than one
  /// did. The row is one of them (the best-ranked, or the one whose group
  /// this is), and this is how it says the others are not missing but the
  /// same thing again. Empty says nothing at all -- including for a source
  /// one addon listed twice, which is the addon repeating itself.
  final List<String> alsoFrom;

  /// What was read out of the stream: a badge for each thing that is
  /// actually known, and an unknown gets no badge rather than a
  /// placeholder.
  ///
  /// Both lists pass one. Null is the "continue with the last source"
  /// row, which says what it is instead of what it holds.
  final StreamFacts? facts;

  /// Whether the heading above this row already names the addon, as the
  /// grouped list's does.
  ///
  /// The two lists show the same row from the same reading, and differ in
  /// exactly one thing: which fact the heading has already said. The
  /// sectioned list is headed by a resolution, so the row names the addon
  /// under the release; the grouped list is headed by the addon, so it
  /// does not say it twice. Everything else -- the release, the badges --
  /// is the same either way, and that is the point of the flag.
  final bool headedByAddon;
  final VoidCallback? onTap;
  final bool highlighted;
  final IconData? leadingIcon;
  final String? titleOverride;

  /// The offline downloads, when there is a client above this screen.
  final _StreamDownloads? downloads;

  @override
  Widget build(BuildContext context) {
    final hints = StreamHints.of(stream);
    final facts = this.facts;
    // The release, not the addon. `stream.title` is `name ?? description`,
    // which for the addons people actually install is their own name and a
    // quality -- "Torrentio 4k" -- so a phone showed the release nowhere in
    // the flat list and only as a subtitle in the grouped one. The
    // television was given [releaseNameOf] when its cards were rebuilt;
    // this is the same derivation, in the list the phone draws.
    final release = releaseNameOf(stream, addonName: facts?.addonName);
    final title = titleOverride ?? release;
    // A row whose whole name is the hint ("1080p", which is all some
    // addons call a stream) needs no badge saying it again. The badges
    // are read now rather than pulled out of the free text, so this is
    // checked against what the row is actually headed with -- the badges
    // repeat the title just as readily as the old chips did, and a row
    // reading "1080p / 1080p / 2 GB" is what it looks like when nobody
    // checks.
    final chips = [
      for (final chip in facts?.badges ?? hints.chips)
        if (chip.toLowerCase() != title.toLowerCase()) chip,
    ];
    // Which fact the heading above has not already said. For the
    // "continue" row, which has no heading and no reading, it is what the
    // source calls itself.
    final description = facts == null
        ? stream.title
        : headedByAddon
        ? null
        : facts.addonName;
    final isTv = DeviceScope.isTv(context);
    final alsoFrom = this.alsoFrom.isEmpty
        ? null
        : alsoFromLabel(this.alsoFrom);
    final lines =
        [description, alsoFrom].nonNulls.length + (chips.isEmpty ? 0 : 1);
    final tile = ListTile(
      enabled: onTap != null,
      selected: highlighted,
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
      onLongPress: downloads?.remoteAction(stream),
      child: withTooltip,
    );
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
      // The same button for a download that stopped and one whose pieces
      // are gone: both are "press to have this file again", and the
      // tooltip is what tells them apart.
      DownloadState.error => IconButton(
        tooltip: kDownloadRetryTooltip,
        icon: const Icon(Icons.error_outline),
        onPressed: start,
      ),
      DownloadState.gone => IconButton(
        tooltip: kDownloadGoneTooltip,
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
