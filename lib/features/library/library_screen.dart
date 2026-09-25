import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../widgets/content_type_label.dart';
import '../../widgets/filter_controls.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/library_item_tile.dart';
import '../details/meta_details_screen.dart';
import '../downloads/downloads_screen.dart';
import '../drive/drive_match.dart';
import '../drive/linked_files.dart';
import '../drive/remote_files.dart';
import '../similar/similar_resolver.dart';

/// The library (`library`, a `LibraryWithFilters<NotRemovedFilter>`): every
/// title added or followed, filtered by type and sorted.
///
/// On mount it dispatches `Load LibraryWithFilters` for every type sorted by
/// last watched; the engine answers with `selectable` (the types present,
/// the six sorts, the next page) where every entry carries the request that
/// selects it, and the filter row dispatches those verbatim. `catalog` is
/// cumulative — `LoadNextPage` makes the engine publish a longer list, so
/// the grid replaces its items rather than appending. Item actions (remove,
/// mark watched, rewind, notifications) are `Ctx` actions; the engine
/// refreshes this field on its own after each. The field is unloaded on
/// dispose; the anonymous library is shown with a hint to sign in, and a
/// signed-in profile gets a "Sync now" button.
///
/// The filter row also carries the way to the [DownloadsScreen]: what is
/// kept on the device is a view of the library rather than a place of its
/// own, and a chip next to the type filters is where one would look for it.
///
/// It carries **Remote** for a related but not identical reason, and the
/// difference is the whole of why that option is built the way it is: see
/// [_FilterRow] and [_remote].
///
/// A matched linked Drive file appears under the ordinary options too, and
/// that is a merge of *the list* and of nothing else: the cards the engine
/// sent are checked for the one a matched file belongs to, and only the
/// missing ones are drawn after them. No pill is invented, nothing is
/// dispatched and nothing is written to the engine's library. See
/// [_appended].
///
/// The app bar carries the [RemoteFilesButton]. A file on the viewer's own
/// Drive is theirs; the board is what an addon catalogue offers, which is
/// why the button moved here.
///
/// On a TV the filter row and the grid are separate [FocusTraversalGroup]s,
/// the tiles remember which one had focus for the shell's per-tab memory,
/// the remote's menu key or a held select opens an item's actions (what a
/// long press does on a phone), and the sheet puts focus on its first
/// action so the D-pad can walk it.
///
/// **And no `TvLadder`, which is a decision and not an omission.** The board
/// carried two rungs for this very button and they did not come with it,
/// because the two screens differ in exactly the property a ladder is for.
/// On the board the thing under the bar is a row of posters: nothing is in
/// the button's own vertical band, so up from a poster takes a corner of the
/// bar and down out of the bar re-sorts every node on the page by horizontal
/// distance. Here the thing under the bar is the filter row, which spans the
/// width, so "the nearest node in that direction" and "the next region down"
/// are the same answer and geometry gets it right on its own --
/// `library_focus_test.dart` walks every step of it.
///
/// It is also the wrong tool for this row, measured: a rung hands the remote
/// back to a *stop index* it remembers, and this row's stops are chips
/// wrapped in [FocusMarked], whose focus nodes re-attach as they rebuild. The
/// index names a different control from one press to the next, which is the
/// scheme-disagreeing-with-the-drawing failure wearing a ladder's clothes.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    this.driveOpener = const ServerDriveFileOpener(),
    this.driveSearch = cinemetaSearch,
    this.driveLister = const XtremioDriveFileLister(),
  });

  /// How a linked Drive file is turned into something playable, for the
  /// Remote list. A parameter for the reason `DrivePairingScreen.opener` is
  /// one: a widget test must not be pointed at the deployed server.
  final DriveFileOpener driveOpener;

  /// How the catalogue is asked when a linked Drive file is matched to a
  /// title, for the same reason: a widget test answers it with a list rather
  /// than reaching Cinemeta. This screen owns that pass -- see
  /// [_LibraryScreenState._matching] -- so the seam is here and not on the
  /// Remote list.
  final CatalogueSearch driveSearch;

  /// How Drive is asked what the linked files are called now, for **Reload**
  /// -- and for the same reason again: the real one goes to the pairing
  /// service and to Google, and a widget test goes to neither.
  final DriveFileLister driveLister;

  /// From this width on, types are a segmented button rather than chips.
  static const double wideBreakpoint = 720;

  /// The initial request: every type, last watched first, page 1.
  static const LibraryRequest initialRequest = LibraryRequest();

  /// Display names of `library_with_filters::Sort`, in the engine's order.
  static String sortLabel(String sort) => switch (sort) {
    LibrarySort.lastWatched => 'Last watched',
    LibrarySort.name => 'Name (A–Z)',
    LibrarySort.nameReverse => 'Name (Z–A)',
    LibrarySort.timesWatched => 'Times watched',
    LibrarySort.watched => 'Watched',
    LibrarySort.notWatched => 'Not watched',
    _ => capitalise(sort),
  };

  /// Label of the `type: null` entry.
  static const String allTypesLabel = 'All';

  /// Label of the app's own option, which is not one of the engine's types.
  ///
  /// Not "Google Drive", and not "Linked": the same word as the button that
  /// links them, because a share on a NAS arrives under it too.
  static const String remoteLabel = 'Remote';

  /// Label of the button beside it, drawn only while it is on.
  ///
  /// One word, and the same word the note above the list tells a viewer to
  /// press (`LinkedDriveFilesView.matchedByNameNote`). Not "Refresh": what
  /// it does is fetch the list again, and refresh is what a television does
  /// sixty times a second.
  static const String reloadLabel = 'Reload';

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _library;
  CoreFieldNotifier? _ctx;
  StreamSubscription<CoreEvent>? _events;
  int _nextPageRequestedAt = -1;

  /// A `SyncLibraryWithAPI` is in flight. The engine has no state for it,
  /// so this is cleared by the `LibrarySyncWithAPIPlanned` event (or the
  /// `Error` whose source is that event).
  bool _syncing = false;

  /// The **Remote** option is the one showing, so the body is the linked
  /// Drive files rather than the engine's grid.
  ///
  /// **This is how a local option lives beside engine-driven ones.** The type
  /// pills are not the app's: they come from `selectable.types`, each one
  /// carries the request that selects it, and pressing one dispatches that
  /// request verbatim and then re-renders from the `selected` flags the
  /// engine sends back. The engine has never heard of Google Drive and is
  /// never going to, so Remote cannot be one of them -- a synthetic entry
  /// with a sentinel request would need a branch at the dispatch and a
  /// second, local notion of which entry is current, and two notions of
  /// "which one is selected" is two pills drawn as current the first time
  /// they disagree.
  ///
  /// So Remote is not a type and does not pretend to be one. It is a
  /// [FilterChip] beside the types rather than one of them -- a different
  /// widget because it is a different kind of thing -- and the whole of what
  /// it does is decide **which body this screen draws**. It dispatches
  /// nothing, and it undispatches nothing:
  ///
  ///  * The engine's selection is untouched while Remote is on. It is drawn
  ///    as not-current, because it is not what the body is showing, but
  ///    nothing was sent to change it and nothing has to be sent to get it
  ///    back -- turning Remote off redraws the engine's own `selected` flags,
  ///    which the engine still holds.
  ///  * Any engine control turns Remote off and does exactly what it did
  ///    before. A press on a type or a sort is a press that means "show me
  ///    the engine's list", so there is nothing inert on the row and nothing
  ///    to fight over.
  ///  * A core reload cannot take the option away, because the option is not
  ///    in the field. `selectable` arriving again republishes the engine's
  ///    pills; this flag is the screen's, and the two cannot clobber each
  ///    other in either direction.
  ///
  /// The row that holds it is drawn whether or not the engine has anything
  /// to say, which is the other half of not vanishing: see [_FilterRow].
  ///
  /// **What this is not: the merge is not this.** A matched linked file also
  /// appears under the ordinary type options -- see [_appended] -- and that
  /// is a different mechanism on purpose. This flag *replaces* the body; the
  /// merge *adds to* it, without touching this row at all.
  bool _remote = false;

  /// A reload is in flight, so a second press is dropped. Nothing is drawn
  /// from it: a chip that turned into a spinner under a viewer's thumb is a
  /// chip a remote loses its focus on, and the answer to "did that do
  /// anything" is the sentence the reload finishes with.
  bool _reloading = false;

  /// This device's Drive pairing, as it was last read off the scope.
  DriveAccount? _drive;

  /// **The one matching pass over the linked files, and the only one.**
  ///
  /// It lives here rather than in [LinkedDriveFilesView] because matching
  /// is not about the Remote list: it is what decides whether a linked file
  /// has a card under **Movies**, **Series** and **All** at all
  /// ([_appended]), and those are this screen's. While the run belonged to
  /// the Remote view, a file linked and never looked at under Remote had no
  /// match and so appeared nowhere -- a viewer who linked a film and came
  /// straight to their library saw an empty page, with nothing on it to say
  /// why.
  ///
  /// **One run, so one notion of "already asked".** [DriveMatchRun] claims
  /// each file in its own `_asked` set before it awaits, and that is the
  /// whole of what stops a file being searched for twice; a second run
  /// beside it would be a second set that knew nothing of the first, and
  /// two passes walking the same files. So this is the only [DriveMatchRun]
  /// the app builds -- the Remote list starts none and is handed none, it
  /// draws what the account holds -- and **Reload** clears this one
  /// ([DriveMatchRun.askAgain]) rather than signalling a view to clear its
  /// own.
  DriveMatchRun? _matching;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _library?.dispose();
      _ctx?.dispose();
      _events?.cancel();
      _client = client;
      _library = CoreFieldNotifier(client, CoreField.library);
      _ctx = CoreFieldNotifier(client, CoreField.ctx);
      _events = client.events.listen(_onEvent);
      _nextPageRequestedAt = -1;
      client.dispatch(CoreActions.loadLibrary(LibraryScreen.initialRequest));
    }
    // The Drive account is depended on *here* and not only inside the build
    // that merges its matches, and that is what makes this method the
    // driver. [DriveAccountScope] is an [InheritedNotifier], so the
    // dependency registered here outlives every rebuild: the account
    // notifying -- a pairing screen linking a file, a Reload renaming one,
    // a match being written down -- brings this method round again, which
    // is exactly the list of occasions on which there might be something
    // new to ask Cinemeta about. Nothing waits for a build to be the trigger
    // and nothing runs per frame.
    final drive = DriveAccountScope.maybeOf(context);
    if (_drive != drive) {
      _drive = drive;
      _matching = drive == null
          ? null
          : DriveMatchRun(account: drive, search: widget.driveSearch);
    }
    _matchLinkedFiles();
  }

  /// Asks about every linked file that has no match yet, without being
  /// waited for.
  ///
  /// `unawaited` and sequential, because neither half of what this feeds is
  /// allowed to wait on a catalogue: the library grid draws the engine's own
  /// cards long before Cinemeta has answered about anybody's Drive, and the
  /// Remote list draws every row perfectly well without a match. Each answer
  /// is written to the account, which notifies, which redraws the one card
  /// or row it was about -- and brings [didChangeDependencies] round again,
  /// where a pass with nothing left to ask about is a walk over the files
  /// and no request at all.
  void _matchLinkedFiles() {
    final matching = _matching;
    if (matching != null) unawaited(matching.run());
  }

  @override
  void dispose() {
    _client?.dispatch(CoreActions.unload(CoreField.library));
    _events?.cancel();
    _library?.dispose();
    _ctx?.dispose();
    super.dispose();
  }

  void _onEvent(CoreEvent event) {
    if (!_syncing || event is! RuntimeCoreEvent) return;
    final settled = switch (event.name) {
      'LibrarySyncWithAPIPlanned' => true,
      'Error' => _errorSource(event) == 'LibrarySyncWithAPIPlanned',
      _ => false,
    };
    if (settled && mounted) setState(() => _syncing = false);
  }

  /// The `source.event` of an `Error` event, when it has one. Only the name
  /// is read: the args of an error can carry account details.
  static String? _errorSource(RuntimeCoreEvent event) {
    final args = event.args;
    if (args is! Map<String, dynamic>) return null;
    final source = args['source'];
    return source is Map<String, dynamic> ? source['event'] as String? : null;
  }

  /// Selects one of the engine's own options: its request, verbatim, and the
  /// local option off, because an engine option means "the engine's list".
  void _select(LibraryRequest request) {
    _nextPageRequestedAt = -1;
    if (_remote) setState(() => _remote = false);
    _client?.dispatch(CoreActions.loadLibrary(request));
  }

  void _showRemote({required bool remote}) {
    if (_remote != remote) setState(() => _remote = remote);
  }

  /// Asks Drive what the linked files are called now, and says what came of
  /// it in one line.
  ///
  /// **Every outcome is a sentence and none of them is a state.** A reload
  /// that reconciled nothing, one that could not reach Google, and one that
  /// found the grant revoked are all a snack bar -- the same register as a
  /// file that would not play ([driveFailureMessage]) -- because there is
  /// nothing on this screen for a viewer to clear, retry or dismiss. The
  /// one that says "nothing has changed" is not padding: a button that
  /// answers with silence is a button pressed again.
  ///
  /// No scope above this is the same picture as a device nobody has paired.
  /// It is a build of the app that cannot link anything, so the line it
  /// gets is the one for no account.
  Future<void> _reloadRemote() async {
    if (_reloading) return;
    final account = DriveAccountScope.maybeOf(context);
    if (account == null) {
      _sayReload(const DriveReloadRefused(DriveListingFailure.notLinked));
      return;
    }
    _reloading = true;
    final DriveReloaded outcome;
    try {
      outcome = await reloadLinkedDriveFiles(
        account: account,
        lister: widget.driveLister,
      );
    } finally {
      _reloading = false;
    }
    if (!mounted) return;
    // Only a whole listing counts: a refusal changed nothing, so there is
    // nothing new for the matching pass to be told about either.
    //
    // Whatever the reload renamed has already lost its match and will be
    // asked about on its own; [DriveMatchRun.askAgain] is the other half,
    // the files that matched nothing and kept their names, which the run
    // would otherwise remember as hopeless for the rest of the session.
    // Said straight to the run, because the run is this screen's -- there
    // is no count handed down to a view to mean this.
    if (outcome is DriveReloadDone) {
      _matching?.askAgain();
      _matchLinkedFiles();
    }
    _sayReload(outcome);
  }

  void _sayReload(DriveReloaded outcome) =>
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(driveReloadMessage(outcome))));

  bool _onScroll(ScrollNotification notification, LibraryState state) {
    if (notification.metrics.extentAfter < 600 &&
        state.hasNextPage &&
        _nextPageRequestedAt != state.items.length) {
      _nextPageRequestedAt = state.items.length;
      _client?.dispatch(CoreActions.loadLibraryNextPage());
    }
    return false;
  }

  void _sync() {
    if (_syncing) return;
    setState(() => _syncing = true);
    _client?.dispatch(CoreActions.syncLibraryWithAPI());
  }

  void _openDownloads() {
    Navigator.of(context).push(DownloadsScreen.route());
  }

  void _open(LibraryItemView item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MetaDetailsScreen(
          type: item.type,
          id: item.id,
          videoId: item.videoId,
        ),
      ),
    );
  }

  Future<void> _showActions(LibraryItemView item) async {
    final action = await showModalBottomSheet<_ItemAction>(
      context: context,
      builder: (_) => _ItemActionsSheet(item: item),
    );
    if (action == null) return;
    _client?.dispatch(switch (action) {
      _ItemAction.remove => CoreActions.removeFromLibrary(item.id),
      _ItemAction.markWatched => CoreActions.libraryItemMarkAsWatched(
        item.id,
        watched: !item.isWatched,
      ),
      _ItemAction.rewind => CoreActions.rewindLibraryItem(item.id),
      _ItemAction.toggleNotifications =>
        CoreActions.toggleLibraryItemNotifications(
          item.id,
          disabled: !item.notificationsDisabled,
        ),
    });
  }

  /// The matched linked files that belong in the body being drawn, after the
  /// engine's own items.
  ///
  /// **A merge of the list, and nothing else.** The engine answers with a
  /// page of cards; each matched linked file asks whether the card it
  /// belongs to is among them, and only the ones with no card there are
  /// drawn. Nothing is dispatched, nothing is written to the engine's
  /// library, and [LibrarySelectable.types] is untouched -- so there is no
  /// second opinion anywhere about which option is current, which is the
  /// one thing an arrangement like this has to avoid.
  ///
  /// [LinkedDriveFiles.unlistedMatches] holds the rule: the card and not the
  /// file, one card per title, and the engine's own `selected.request.type`
  /// compared against the match's own type word. Read from the engine and
  /// never re-derived.
  ///
  /// The order is link order, newest first, after everything the engine
  /// sent. A linked file has never been watched, so interleaving it into a
  /// `lastwatched` sort would be inventing the one thing it does not have.
  ///
  /// Nothing is subtracted for **Remote**, and nothing needs to be: that
  /// option replaces the body rather than filtering it, so this list simply
  /// is not the thing drawn while it is on.
  ///
  /// **What a merged card does not get** is everything the engine derives
  /// from its own library: no continue-watching row, no notifications, no
  /// place in a sync, and no long-press actions -- "remove from library" on
  /// a title the library does not hold is an offer that cannot be kept.
  /// That is the accepted price of not writing, and the alternative was
  /// worse: a write syncs to a Stremio account and puts a title on a phone
  /// that cannot play it, and makes "remove from library" and "unlink" two
  /// acts a viewer expects to be one.
  ///
  /// [context] is the one being built rather than the screen's own, so that
  /// the [DriveAccountScope] dependency is registered where it is read: the
  /// account notifies when a match is written, and this list is what has to
  /// be recomputed when it does.
  List<LinkedDriveMatch> _appended(BuildContext context, LibraryState? state) {
    // An unloaded field has no selection to read, and a merge that guessed
    // at one would be the second opinion this whole arrangement avoids.
    if (state == null || !state.isLoaded) return const [];
    // A build of the app that cannot link anything has nothing to merge,
    // which is not a failure to report -- the same reading the Remote list
    // makes of a missing scope.
    final files = DriveAccountScope.maybeOf(context)?.files;
    if (files == null) return const [];
    return files.unlistedMatches(
      listed: {for (final item in state.items) item.id},
      type: state.selected!.type,
    );
  }

  bool get _isLoggedIn {
    final ctx = _ctx?.value;
    return ctx != null && ProfileState.fromCtx(ctx).isLoggedIn;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_library!, _ctx!]),
      builder: (context, _) {
        final json = _library!.value;
        final state = json == null ? null : LibraryState.fromJson(json);
        final appended = _appended(context, state);
        final isLoggedIn = _isLoggedIn;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Library'),
            actions: [
              if (isLoggedIn)
                _syncing
                    ? const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        tooltip: 'Sync now',
                        icon: const Icon(Icons.sync),
                        onPressed: _sync,
                      ),
              const RemoteFilesButton(),
            ],
          ),
          body: Column(
            children: [
              _tvGroup(
                context,
                _FilterRow(
                  // The engine's half of the row, empty until it has
                  // loaded something: its options are meaningless
                  // without its state, and a type filter over a library
                  // that is still arriving would offer types nothing is
                  // in.
                  selectable:
                      state != null && state.isLoaded && !state.isLibraryEmpty
                      ? state.selectable
                      : const LibrarySelectable.empty(),
                  remote: _remote,
                  onSelect: _select,
                  onRemote: (on) => _showRemote(remote: on),
                  onReload: () => unawaited(_reloadRemote()),
                  onDownloads: _openDownloads,
                ),
              ),
              if (!isLoggedIn &&
                  !_remote &&
                  state != null &&
                  !state.isLibraryEmpty)
                const _SignInHint(),
              Expanded(
                child: _remote
                    ? _tvGroup(
                        context,
                        LinkedDriveFilesView(opener: widget.driveOpener),
                      )
                    : state == null || !state.isLoaded
                    ? const Center(child: CircularProgressIndicator())
                    // Both "nothing here" messages are about an empty
                    // *body*, and the body is no longer the engine's
                    // catalog alone: a viewer who has just linked a film
                    // into an otherwise empty library is the most likely
                    // of anybody to be hunting for it, and a page saying
                    // there is nothing with the thing they are looking for
                    // one merge away is the worst answer on this screen.
                    // The engine still decides *which* message, because it
                    // is the engine's filter either one is about.
                    : !state.isEmpty || appended.isNotEmpty
                    ? _tvGroup(context, _buildGrid(state, appended))
                    : state.isFilteredEmpty
                    ? _EmptyFilter(type: state.selected!.type!)
                    : _EmptyLibrary(isLoggedIn: isLoggedIn),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The engine's items, then [appended] -- one lazy grid and not two, so
  /// that merging a card does not cost a page of tiles that nobody has
  /// scrolled to. The count grows by what was appended and the builder
  /// picks the list by index; nothing walks the engine's items to build
  /// them.
  Widget _buildGrid(LibraryState state, List<LinkedDriveMatch> appended) {
    final items = state.items;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) => _onScroll(n, state),
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 160,
          childAspectRatio: 0.56,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        itemCount: items.length + appended.length,
        itemBuilder: (context, index) {
          if (index >= items.length) {
            final match = appended[index - items.length];
            return LibraryItemTile(
              item: _cardFor(match),
              // The Remote list's press, shared rather than written twice.
              onTap: () => openDriveMatch(context, match),
              // And no long press: every action in that sheet is a `Ctx`
              // action about a library item, and this title is not one.
              memoryId: 'linked-${match.cinemetaId}',
            );
          }
          final item = items[index];
          return LibraryItemTile(
            item: item,
            onTap: () => _open(item),
            onLongPress: () => _showActions(item),
            memoryId: item.id,
          );
        },
      ),
    );
  }

  /// [match] as the card it belongs to.
  ///
  /// A [LibraryItemView] and not a tile of its own, so that a merged card is
  /// drawn by the same widget as its neighbours and cannot drift from them:
  /// the poster treatment, the caption and the shape are the grid's, not a
  /// second copy of them. The poster is [LinkedDriveMatch.posterUrl], which
  /// is the id and not a stored string.
  ///
  /// **What is deliberately absent is everything that would be invented.**
  /// No `state`: no progress bar, no watched mark, no notification badge and
  /// no episode caption -- the card is the *show*, and three linked episodes
  /// of it are one card, so naming one of them under the poster would be a
  /// claim about the card that the card cannot make. The press still opens
  /// the episode, because that is what the file is.
  static LibraryItemView _cardFor(LinkedDriveMatch match) => LibraryItemView({
    '_id': match.cinemetaId,
    'type': match.type,
    'name': match.name,
    'poster': match.posterUrl,
  });

  /// [child] as its own traversal group on a TV; [child] itself elsewhere.
  static Widget _tvGroup(BuildContext context, Widget child) =>
      DeviceScope.isTv(context) ? FocusTraversalGroup(child: child) : child;
}

/// The types present in the library and the sort, plus the two options that
/// are the app's own.
///
/// Stateless over the engine's half: [onSelect] gets the request the engine
/// attached to the chosen entry, and nothing about which one is current is
/// decided here.
///
/// **Two of these controls are not the engine's, and they are not the same
/// as each other.** "Downloaded" is a way to another screen: nothing in the
/// engine knows about downloads, and what is kept on the device is a place
/// of its own, so it is an [ActionChip] and pressing it navigates. "Remote"
/// selects: it changes what this screen's body is, which is what a type pill
/// does, so it is drawn as a pill that can be current -- but a [FilterChip]
/// rather than the [ChoiceChip]s beside it, because it is not one of the
/// engine's choices and a widget tree that said it was would be the first
/// place the two got confused. See [LibraryScreen._remote].
///
/// **The row is drawn whether the engine has anything to say or not.** It
/// used to appear only once a non-empty library had loaded, which was fine
/// while every control on it was the engine's -- and is exactly how a local
/// option vanishes. Remote is true of this device whatever the core is
/// doing, and a viewer whose library is empty is the *most* likely to be
/// looking for the file they just linked. So the engine's controls come and
/// go with its state (an empty [LibrarySelectable] draws neither), and the
/// app's own are always there.
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.selectable,
    required this.remote,
    required this.onSelect,
    required this.onRemote,
    required this.onReload,
    required this.onDownloads,
  });

  final LibrarySelectable selectable;

  /// The local option is the one showing, so none of the engine's is drawn
  /// as current -- without anything having been dispatched to make that so.
  final bool remote;

  final ValueChanged<LibraryRequest> onSelect;

  /// Turns the local option on and off. A press on it is the only way off it
  /// besides pressing one of the engine's, which is what a pill that can be
  /// current owes a viewer: a control that will not let go is a control they
  /// have to guess their way out of.
  final ValueChanged<bool> onRemote;

  /// Asks Drive what the linked files are called now. Only reachable while
  /// [remote] is on, because it is about the list that is on screen then
  /// and about nothing else: a Reload sitting beside the engine's types
  /// would be a button whose subject a viewer has to guess.
  final VoidCallback onReload;

  final VoidCallback onDownloads;

  static const String downloadedLabel = 'Downloaded';

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.sizeOf(context).width >= LibraryScreen.wideBreakpoint;
    final types = [
      for (final type in selectable.types)
        FilterOption(
          label: switch (type.type) {
            null => LibraryScreen.allTypesLabel,
            final type => contentTypeLabel(type),
          },
          // Drawn as not-current while the local option is: the body is not
          // showing the engine's list, and two pills lit at once is the one
          // thing this arrangement has to avoid. Nothing was dispatched to
          // make this so, so the engine's own selection is still whatever it
          // was.
          selected: type.selected && !remote,
          request: type.request,
        ),
    ];
    final sorts = [
      for (final sort in selectable.sorts)
        FilterOption(
          label: LibraryScreen.sortLabel(sort.sort),
          selected: sort.selected,
          request: sort.request,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (types.isNotEmpty)
            isWide
                ? FilterSegments(options: types, onSelect: onSelect)
                : FilterChips(options: types, onSelect: onSelect),
          // Beside the types and before the sort, because it is a choice of
          // what to look at and the sort is a choice about the list. A chip
          // in both layouts: at wide widths the engine's types become one
          // segmented button, and a local option added as a segment of it
          // would be inside the control whose selection is the engine's.
          FocusMarked(
            borderRadius: FocusMarked.stadium,
            child: FilterChip(
              avatar: const Icon(Icons.cloud_outlined, size: 18),
              label: const Text(LibraryScreen.remoteLabel),
              selected: remote,
              onSelected: onRemote,
            ),
          ),
          // Next to the pill it belongs to, and only while that pill is on.
          // It is an [ActionChip] and not a second [FilterChip] for the
          // reason Downloaded is one: pressing it does something and then it
          // is over, where a pill says what the body is showing. Wrapped
          // like the rest of the row, because the floor fills a chip and
          // cannot outline one.
          if (remote)
            FocusMarked(
              borderRadius: FocusMarked.stadium,
              child: ActionChip(
                avatar: const Icon(Icons.refresh, size: 18),
                label: const Text(LibraryScreen.reloadLabel),
                onPressed: onReload,
              ),
            ),
          if (sorts.isNotEmpty)
            FilterMenu(label: 'Sort', options: sorts, onSelect: onSelect),
          // Wrapped for the same reason the filter chips are: the floor
          // fills a chip and cannot outline one.
          FocusMarked(
            borderRadius: FocusMarked.stadium,
            child: ActionChip(
              avatar: const Icon(Icons.download_done_outlined, size: 18),
              label: const Text(downloadedLabel),
              onPressed: onDownloads,
            ),
          ),
        ],
      ),
    );
  }
}

enum _ItemAction { remove, markWatched, rewind, toggleNotifications }

/// The long-press menu of one item.
class _ItemActionsSheet extends StatelessWidget {
  const _ItemActionsSheet({required this.item});

  final LibraryItemView item;

  @override
  Widget build(BuildContext context) {
    void pick(_ItemAction action) => Navigator.of(context).pop(action);
    // A remote has nothing to point with: the first action takes focus so
    // up, down and select work from the start.
    final isTv = DeviceScope.isTv(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            autofocus: isTv,
            leading: Icon(
              item.isWatched
                  ? Icons.remove_done_outlined
                  : Icons.done_all_outlined,
            ),
            title: Text(
              item.isWatched ? 'Mark as not watched' : 'Mark as watched',
            ),
            onTap: () => pick(_ItemAction.markWatched),
          ),
          ListTile(
            leading: const Icon(Icons.replay_outlined),
            title: const Text('Rewind'),
            onTap: () => pick(_ItemAction.rewind),
          ),
          ListTile(
            leading: Icon(
              item.notificationsDisabled
                  ? Icons.notifications_outlined
                  : Icons.notifications_off_outlined,
            ),
            title: Text(
              item.notificationsDisabled
                  ? 'Enable notifications'
                  : 'Disable notifications',
            ),
            onTap: () => pick(_ItemAction.toggleNotifications),
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_remove_outlined),
            title: const Text('Remove from library'),
            onTap: () => pick(_ItemAction.remove),
          ),
        ],
      ),
    );
  }
}

/// Shown above a non-empty anonymous library.
class _SignInHint extends StatelessWidget {
  const _SignInHint();

  static const String text = 'Sign in to sync';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$text: this library lives on this device only '
              '(Settings → Account).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the selected type matches nothing while the library is not
/// empty; the filter row above it still offers "All".
class _EmptyFilter extends StatelessWidget {
  const _EmptyFilter({required this.type});

  final String type;

  /// The message for [type] (`'No movies in your library'`; an acronym
  /// such as `TV` keeps its case).
  static String message(String type) {
    final label = contentTypeLabel(type);
    final word = label == label.toUpperCase() ? label : label.toLowerCase();
    return 'No $word in your library';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_list_off_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(message(type), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Pick "${LibraryScreen.allTypesLabel}" above to see every '
              'title you have.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.isLoggedIn});

  final bool isLoggedIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('Your library is empty', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              isLoggedIn
                  ? 'Add titles from their details page and they show '
                        'up here on every device.'
                  : '${_SignInHint.text} — sign in to your Stremio account '
                        'in Settings to get your library on this device.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
