import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/tv_density.dart';
import '../../widgets/filter_controls.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/tv_ladder.dart';
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
import 'details_header.dart';
import 'similar_row.dart';
import 'stream_facts.dart';
import 'stream_list.dart';
import 'stream_sources.dart';
import 'tv_backdrop.dart';
import 'tv_episode_row.dart';
import 'tv_meta_header.dart';
import 'tv_source_row.dart';

export 'stream_list.dart'
    show
        driveSourceStorageLabel,
        kAddonHadNothing,
        kContinueWatchingLabel,
        kContinueWithLastSource,
        kEpisodesLabel,
        kLookingForStreams,
        kNothingCameBack,
        kSourceAccountingLabel,
        kSourcesLabel,
        kStreamsGroupedLabel,
        kStreamsSectionedLabel,
        streamAddonKey,
        streamSectionKey;

part 'meta_details_derivation.dart';
part 'meta_details_downloads.dart';
part 'meta_details_info.dart';
part 'meta_details_streams.dart';
part 'meta_details_tv_sources.dart';

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

/// The rungs of this screen's [TvLadder], top to bottom: the choices a
/// viewer makes on the way to a stream, in the order they make them.
///
/// Numbered with gaps because most of them are conditional -- a film has
/// no seasons or episodes, a title nobody has played has no last-used
/// source, and the row of sources only exists while a group is open.
/// Only what is drawn is registered, and a press walks past the rest. On
/// a television most of these sit inside a [TvLadderRung], whose header
/// is a rung of the walk in its own right: the walk goes header, header,
/// header down the screen, and only the open rung puts its own rows
/// between two of them.
///
/// **The numbers are the order things are drawn down the panel**, though
/// two methods build them: the title and the episodes come from
/// [_infoSlivers], everything from the last-used source down from
/// [_tvSourceSlivers], and the panel lays them out info-then-sources. The
/// ladder walks these numbers and the viewer walks the panel, so a number
/// out of order is a rung the D-pad cannot reach from its neighbour.
///
/// This one has no row under it. The bar's Back and its actions sit in
/// the bar's own slots, which no one widget can wrap, so they are not a
/// row of the ladder -- but a press down out of one has to land on the
/// ladder all the same, and this is the level it enters from
/// ([_AboveTheLadder]).
const int _ladderAppBar = -10;

/// The block above the pills: on a television the title, its facts and
/// the bookmark. A rung, so a press down from the bookmark reaches the
/// pills rather than whatever geometry finds below a narrow row packed at
/// the left, which would leave the episode row arrived at sideways and
/// its memory of where the viewer was overwritten.
const int _ladderInfo = 0;
const int _ladderEpisodesHeader = 20;
const int _ladderSeasons = 24;
const int _ladderEpisodes = 28;
const int _ladderLastUsedHeader = 30;
const int _ladderLastUsed = 35;
const int _ladderSourcesHeader = 40;
const int _ladderStreamControls = 43;
const int _ladderStreamOrder = 46;
const int _ladderGroups = 50;
const int _ladderSources = 55;
const int _ladderSimilarHeader = 60;
const int _ladderSimilar = 65;
const int _ladderAddonsHeader = 70;
const int _ladderAddons = 75;

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
/// The title is *not* put into the library: that would put it in the
/// library of every device on the account, where it is neither downloaded
/// nor linked. The library screen draws it because it is downloaded, and
/// the player records progress offline because the Rust side answers the
/// failed meta fetch from the snapshot (`downloads::kept_meta`), so it
/// builds its own `temp` item as it does online. Playing that same
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
    this.driveOpener = const ServerDriveFileOpener(),
  });

  final String type;
  final String id;

  /// The video to show streams for straight away (the continue-watching
  /// row knows it); without it the engine guesses, or the screen picks.
  final String? videoId;

  /// How a linked Drive file listed among the sources is turned into
  /// something playable. A parameter for the reason `LibraryScreen.driveOpener`
  /// is one: a widget test must not be pointed at the deployed server.
  final DriveFileOpener driveOpener;

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

  /// This device's Google Drive pairing, when the app put one above this
  /// screen. Null leaves the linked files out of the sources list
  /// entirely -- which is also what a paired account with nothing matched
  /// to this title draws.
  DriveAccount? _driveAccount;

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
  /// answer to *is there a rung*: a title that is not a film or a series
  /// is never asked about and draws none ([_maybeAskSimilar]).
  bool _similarAsked = false;

  /// What came back: the titles a catalogue confirmed, in the model's
  /// order. Null while the ask is out -- which is where the header says it
  /// is looking -- and empty when the server had nothing, could not be
  /// asked, or the guard dropped all of it, which takes the rung away
  /// again.
  List<SimilarTitle>? _similar;

  /// Whether there is a "More like this" rung on the panel at all.
  ///
  /// Three states and not two: never asked (not a film or a series) and
  /// asked-and-empty both draw nothing, and the wait between them is a
  /// header that says it is looking.
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
    // Read here for the reason the preferences above are: [DriveAccountScope]
    // is an `InheritedNotifier` too, so a match landing while this screen is
    // up runs this again and the Drive row appears without anything here
    // subscribing to anything.
    _driveAccount = DriveAccountScope.maybeOf(context);
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
  /// known -- which is when the rest of the ladder is drawn, so the rung's
  /// header arrives with it rather than after.
  ///
  /// **Every film and series is asked about.** There is no setting to
  /// wait for: the server holds the key and answers everybody. So the
  /// rung appears saying it is looking on every such title, and on one the
  /// server has nothing for -- no answer, a failure, or a list the guard
  /// emptied -- it goes away again when that empty answer lands
  /// ([_hasSimilar]). Any other type is not asked about at all, because
  /// the server answers only these two and the header would be a promise
  /// the screen already knows it cannot keep.
  void _maybeAskSimilar(MetaDetailsState state) {
    final meta = state.meta;
    final prefs = _prefs;
    if (!mounted || _similarAsked || meta == null || prefs == null) return;
    if (widget.type != 'movie' && widget.type != 'series') return;
    _similarAsked = true;
    unawaited(_similarFor(prefs));
  }

  Future<void> _similarFor(AppPrefs prefs) async {
    final titles = await _askSimilar(prefs)(type: widget.type, id: widget.id);
    // Late by design -- a remembered answer is quick, and the first ask of
    // a title anywhere waits on the model behind the server. Everything
    // about what this must not disturb on the way in is in [_tvSimilarRung].
    if (mounted) setState(() => _similar = titles);
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

  /// Plays one row of the sources list, whichever kind of source it is and
  /// whichever of the two layouts drew it.
  ///
  /// One dispatcher and not a branch per sliver: the two layouts draw the
  /// same row from the same reading, and a press on it has to *do* the same
  /// thing in both as well. A row with no addon group behind it is a linked
  /// Drive file and there is exactly one other kind of row, which is why
  /// this is a null check rather than a switch.
  Future<void> _playRow(MetaDetailsState state, SourceRow row) {
    final drive = row.drive;
    if (drive != null) return _playDrive(state, drive);
    return _play(state, row.group!, row.stream);
  }

  /// Opens a linked Drive file and pushes the player at it: the same route
  /// the library's Remote list takes, by the same two calls, with this
  /// title's meta and subtitles attached -- which is the whole of what
  /// being on a details page adds.
  ///
  /// **With [driveStreamRequest] for the video on screen**, because the
  /// engine keeps a resume position, a watched mark and an up-next only for
  /// a play that has a stream request. It names this app's own service
  /// rather than any installed addon, so no addon is credited with a file
  /// it never offered; see [driveStreamRequest] for what that address
  /// answers.
  ///
  /// What this knows about the credential is that it does not have it:
  /// [openLinkedDriveFile] asks the account, which is the only thing that
  /// holds one, and writes a dead pairing down on the way past -- so a
  /// refusal here is a line to read and never a state to manage.
  Future<void> _playDrive(MetaDetailsState state, LinkedDriveFile file) async {
    final account = _driveAccount;
    if (account == null || _playing) return;
    _playing = true;
    try {
      final opened = await openLinkedDriveFile(
        account: account,
        file: file,
        opener: widget.driveOpener,
      );
      if (!mounted) return;
      switch (opened) {
        case DriveFilePlayable():
          final videoId = state.streamPath?.id ?? state.meta?.id ?? widget.id;
          await Navigator.of(context).push<PlayerScreenResult>(
            MaterialPageRoute<PlayerScreenResult>(
              settings: const RouteSettings(name: PlayerScreen.routeName),
              builder: (_) => PlayerScreen(
                stream: driveStreamJson(file: file, playable: opened),
                streamRequest: driveStreamRequest(
                  type: widget.type,
                  videoId: videoId,
                ),
                metaRequest: state.metaRequest,
                driveOpener: widget.driveOpener,
                subtitlesPath: ResourcePath(
                  resource: 'subtitles',
                  type: widget.type,
                  id: videoId,
                ),
              ),
            ),
          );
        case DriveFileRefused(:final reason):
          _tell(driveFailureMessage(reason));
      }
    } finally {
      _playing = false;
    }
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
  /// volume, a deletion from outside the app) streams instead,
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
    }
    if (!mounted) return;
    final result = await Navigator.of(context).push<PlayerScreenResult>(
      MaterialPageRoute<PlayerScreenResult>(
        settings: const RouteSettings(name: PlayerScreen.routeName),
        builder: (_) => PlayerScreen(
          stream: playback ?? stream.json,
          streamRequest: group.request,
          metaRequest: state.metaRequest,
          driveOpener: widget.driveOpener,
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
}

/// An app bar control on a television, handing a press down to the ladder
/// drawn below the bar.
///
/// The bar is not on the ladder and cannot easily be put on it -- Back and
/// the actions are separate slots of the bar, and one [TvLadderRow] wraps
/// one subtree -- so a press down out of one of them was left to Flutter's
/// directional traversal, which takes the nearest node in the direction
/// pressed. The downloads button is at the far right of the bar and the
/// bookmark is at the far right of the header, directly under it; the
/// description is a block that stops well short of both. So down from
/// downloads landed on the bookmark and down from Back on the description,
/// and reading the plot from the downloads button meant going left to Back
/// first and then down -- which is the report this answers.
///
/// Distance is the wrong question here for the same reason it is wrong
/// between the rows ([TvLadder]): what is under the bar is the header,
/// whatever each control happens to line up with. So the press enters the
/// ladder at [_ladderAppBar] and the header row
/// says where in itself the remote lands -- the plot on a first arrival,
/// and afterwards whichever of its two stops the viewer left it on, the
/// way every other row of the ladder hands the remote back.
///
/// A press the ladder cannot answer is **left alone** rather than
/// swallowed, so directional focus still gets its go: the bar of a screen
/// whose ladder has not been built yet still walks.
///
/// Off a television this is its child and nothing else: a phone's app bar
/// is reached by touch and a desktop's by Tab, and neither asks this
/// question.
class _AboveTheLadder extends StatelessWidget {
  const _AboveTheLadder({required this.isTv, required this.child});

  final bool isTv;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isTv) return child;
    final ladder = TvLadder.maybeOf(context);
    return Focus(
      // Not a stop of its own: it watches the key on its way up from the
      // button below it, the way [TvLadderRow] watches its own row's.
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onKeyEvent: (node, event) {
        if (event is KeyUpEvent ||
            event.logicalKey != LogicalKeyboardKey.arrowDown) {
          return KeyEventResult.ignored;
        }
        final moved = ladder?.move(_ladderAppBar, up: false) ?? false;
        return moved ? KeyEventResult.handled : KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
