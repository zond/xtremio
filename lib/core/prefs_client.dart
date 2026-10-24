import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../src/rust/api/prefs.dart' as rust;
import 'buffer_ahead.dart';
import 'details_visits.dart';
import 'drive_link.dart';
import 'faces.dart';
import 'show_episodes.dart';
import 'local_media_files.dart';
import 'focus_emphasis.dart';
import 'similar_memory.dart';
import 'title_ratings.dart';
import 'stream_order.dart';
import 'subtitle_picks.dart';
import 'subtitle_sync.dart';

/// The app's own preferences, over the Rust side's small JSON file
/// (`rust/src/prefs.rs`, `<storage_dir>/xtremio_prefs.json`).
///
/// These are the *client's* choices, such as how a list is laid out or which
/// view a screen comes up in. They are deliberately not stremio-core `Settings`
/// fields. That struct is the engine's and is synced to the account, and adding
/// to it would mean forking the core. They are deliberately not a Dart
/// preferences package either: the storage directory is already ours and
/// already writes atomically.
///
/// An interface so widget tests can hand [AppPrefs] a map instead of
/// reaching FFI, the way `DiagnosticsClient` works for Diagnostics.
abstract interface class PrefsClient {
  /// Every preference that has been set. An empty map means none has been. A
  /// missing, unreadable or non-object file all read that way, since a
  /// preference is a default the user changed.
  Future<Map<String, dynamic>> getAll();

  /// Stores [value] under [key], or removes the key when it is null. Every
  /// other key in the file survives, including one a newer build wrote.
  Future<void> set(String key, Object? value);
}

/// [PrefsClient] over FFI.
class RustPrefsClient implements PrefsClient {
  const RustPrefsClient();

  @override
  Future<Map<String, dynamic>> getAll() async {
    final decoded = jsonDecode(await rust.prefsGetAll());
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  @override
  Future<void> set(String key, Object? value) => rust.prefsSet(
    key: key,
    valueJson: value == null ? null : jsonEncode(value),
  );
}

/// The preferences the app holds in memory, read once at start-up and
/// written through on every change.
///
/// One of these for the whole app, handed down as a [PrefsScope], because a
/// preference is global: a layout chosen on one title is the layout the
/// next title comes up in. It is a [ChangeNotifier] so the screens that
/// read one rebuild when it changes.
///
/// The defaults stay when [load] fails (nothing has pointed storage anywhere
/// yet, no Rust library under a test). A failed write leaves the value in
/// memory: the choice holds for this run and does not survive a restart. That
/// is a better answer than a control that snaps back under the user's finger.
class AppPrefs extends ChangeNotifier {
  AppPrefs({this.client});

  /// One that persists nothing, for a screen mounted with no [PrefsScope]
  /// above it (a widget test that does not care where the choice goes).
  AppPrefs.inMemory() : this();

  /// Where the values are read from and written to; null persists nothing.
  final PrefsClient? client;

  /// The `streamsSectioned` key: whether the Details screen lists every addon's
  /// streams together, cut into a collapsible section per resolution, instead
  /// of one section per addon. True (sectioned) is the default, which is what a
  /// fresh install shows, since it has never chosen.
  ///
  /// [load] falls back to [legacyStreamsFlatKey] when this key is unset, so an
  /// install that chose under the old name keeps its choice.
  static const String streamsSectionedKey = 'streamsSectioned';

  /// The boolean an install from before the rename may still have under its old
  /// name, `streamsFlat`. [load] reads it only when [streamsSectionedKey]
  /// itself is unset. Nothing here ever writes to it again: the first toggle
  /// after an upgrade moves the choice to the new key, and the old one is left
  /// stale.
  static const String legacyStreamsFlatKey = 'streamsFlat';

  /// The `streamsOrder` key: what order the streams inside one resolution
  /// section of that list are in (see [StreamOrder]). Global for the same
  /// reason [streamsSectionedKey] is — an order chosen on one title is the
  /// order the next title comes up in.
  static const String streamsOrderKey = 'streamsOrder';

  /// The `openStreamSections` key: which resolution sections of the sectioned
  /// sources list are expanded. It holds a list of each section's stored label:
  /// a resolution's own [StreamResolution.label], or `'unknown'` for the
  /// section no resolution could be read for (see `_sectionStorageLabel` in
  /// `meta_details_screen.dart`). It is global and sticky like the layout and
  /// the order: a section opened on one title is open on the next, and after a
  /// restart.
  ///
  /// Every section starts collapsed until the viewer opens one. An empty list
  /// is a real, deliberate value ("collapse everything"), not "nothing chosen
  /// yet". So [load] keeps it apart from a missing key, as it does for
  /// [streamsSectionedKey]. See [openStreamSections].
  static const String openStreamSectionsKey = 'openStreamSections';

  /// The `openStreamAddons` key: which addon groups of the *grouped* sources
  /// list are expanded, as a list of each group's stored label (the addon's
  /// transport URL; see `_addonStorageLabel` in `meta_details_screen.dart`). It
  /// is global and sticky exactly as [openStreamSectionsKey] is, and empty in
  /// the same deliberate way. With nothing remembered every group is shut, on a
  /// fresh install and after the viewer has closed the last one.
  ///
  /// It is a key of its own rather than a share of [openStreamSectionsKey], for
  /// two reasons. An addon may have the same name as a resolution, and one set
  /// cannot tell the two apart: the addon would open a section, or the section
  /// the addon. And they are different questions. What a viewer left open among
  /// resolutions says nothing about which addons they want open, so one
  /// layout's choice must not arrive as the other's.
  static const String openStreamAddonsKey = 'openStreamAddons';

  /// The `bufferAhead` key: how far ahead playback buffers by default (see
  /// [BufferAhead]). The player takes this unless the viewer overrides it
  /// for the playback on screen.
  static const String bufferAheadKey = 'bufferAhead';

  /// The `focusEmphasis` key: how strongly focus is marked on a television (see
  /// [FocusEmphasis]). It is about this device's room and display, not the
  /// account, so it lives here rather than in `profile.settings`.
  static const String focusEmphasisKey = 'focusEmphasis';

  /// The `shareWhileIdle` key: whether the embedded server goes on
  /// uploading to other people when nothing is playing (`IdleSharing`).
  ///
  /// **On until the viewer turns it off.** That is why it is a plain `bool` and
  /// not a `bool?`. The default is the same everywhere, so a missing key and a
  /// stored `true` mean the same thing, and a null has nothing left to say. A
  /// stored `false` is a decision and still survives, which is all the storage
  /// ever had to do.
  static const String shareWhileIdleKey = 'shareWhileIdle';

  /// The `verboseDiagnostics` key: whether the Diagnostics log carries the
  /// streaming server's retention trace (what its cache decided about each file
  /// and why) and mpv's demuxer, stream and cache lines
  /// (`DiagnosticsTraceSync`, `MediaKitEngine.verboseLog`). Off by default.
  /// Both are what a report is read by when playback misbehaves, and noise the
  /// rest of the time, filling the ring the report copies. Like the other
  /// preferences here it belongs to this device, since it is about what this
  /// device's log holds.
  static const String verboseDiagnosticsKey = 'verboseDiagnostics';

  /// The `directVideo` key: whether a film on Android is decoded straight into
  /// its own surface on the display (`VideoOutput.surface`), rather than drawn
  /// into the app's picture by mpv (`VideoOutput.texture`). Off by default
  /// while the surface is new: the films the surface cannot show are handed to
  /// the texture by rules no device has exercised yet. Whether a device's
  /// decoder copes is a fact about the device, so it belongs to this device
  /// rather than to the account.
  static const String directVideoKey = 'directVideo';

  /// The `subtitleSync` key: every subtitle adjustment the viewer has
  /// made that is still remembered (see [SubtitleSyncMemory]), most
  /// recent first.
  ///
  /// Both adjustments share one key because they are the same preference: what
  /// this viewer has already fixed. They are keyed differently, though: a speed
  /// on the series and the release group, a shift on those and the video
  /// release as well. It is a list, so the recency the bound drops by is the
  /// order itself.
  static const String subtitleSyncKey = 'subtitleSync';

  /// The `subtitlePicks` key: which subtitle each show was last watched
  /// with, and how often each language has been picked at all (see
  /// [SubtitlePickMemory]).
  ///
  /// A separate key from [subtitleSyncKey] because it answers a different
  /// question. The sync memory is what the viewer *fixed* about a file's
  /// timing; this is what they *chose*. The panel writes one and the menu the
  /// other, they are read at different moments, and they are forgotten
  /// independently.
  static const String subtitlePicksKey = 'subtitlePicks';

  /// The `localMedia` key: the videos on this device and what each one
  /// matched (see [LocalMediaFiles]).
  static const String localMediaKey = 'localMedia';

  /// The `localFolders` key: the folders a desktop looks for videos in,
  /// chosen in Settings. A phone or a television uses its media index and
  /// never reads this.
  static const String localFoldersKey = 'localFolders';

  /// The `localFolderBookmarks` key: on macOS, each chosen folder's
  /// security-scoped bookmark (base64), which lets a sandboxed app read the
  /// folder again after it quits. It maps folder to bookmark.
  static const String localFolderBookmarksKey = 'localFolderBookmarks';

  /// The `detailsVisits` key: which season and episode each title's
  /// details screen was left on (see [DetailsVisitMemory]).
  static const String detailsVisitsKey = 'detailsVisits';

  /// Keys an older build wrote and this one removes on [load]:
  /// `similarApiKey`, the Gemini key a viewer once pasted so the app could
  /// ask a model itself, and `similarModel`, which model it asked.
  ///
  /// This build asks the xtremio-xervice server for "More like this", and the
  /// server holds the only key there is, so neither means anything here. They
  /// are not merely ignored. The first is a credential, and a credential
  /// nothing reads should not be lying in a file on the device. So a load that
  /// finds either removes it, once, and every later load finds nothing.
  static const List<String> retiredKeys = ['similarApiKey', 'similarModel'];

  /// The `similarSuggestions` key: what the server has already answered
  /// about each title (see [SimilarMemory]).
  ///
  /// It is kept for the life of the install, as the first of two caches. The
  /// server keeps one answer per title for everyone, and this keeps it on the
  /// device. So a title is asked of the server once per install, and its row is
  /// there without a round trip each time it is opened.
  static const String similarSuggestionsKey = 'similarSuggestions';

  /// The `faces` key: what the viewer said about titles -- liked,
  /// disliked, not interested -- kept apart per account they were said
  /// under (see [FacesByAccount]). Ids, times and user ids only.
  static const String facesKey = 'faces';

  /// The `showEpisodes` key: each series' episode list as the For you row
  /// last asked Cinemeta for it (see [ShowEpisodesMemory]).
  static const String showEpisodesKey = 'showEpisodes';

  /// The `forYou` key: the For you row as last worked out -- its titles,
  /// their reasons, when, a signature of the sources, and whether a source
  /// did not answer (`ForYouController`). Kept as the controller wrote it.
  static const String forYouKey = 'forYou';

  /// The `titleRatings` key: the scores the server has told this device
  /// about each title (see [TitleRatingsMemory]), so a title opened again
  /// shows them in its first frame.
  static const String titleRatingsKey = 'titleRatings';

  /// The `driveLinkedFiles` key: which Google Drive files a pairing has
  /// linked to this device (see [LinkedDriveFiles]).
  ///
  /// It lives here, not in the [SecretStore] beside the refresh token, because
  /// it is not a secret. File ids and filenames are the same kind of thing as
  /// the library, and a viewer looking at this file learns nothing they could
  /// use. The token is the secret, and it is the only thing kept anywhere else.
  /// Keeping the list here also makes the Drive screen cheap to build: it is
  /// already in memory with the rest of the preferences, and nothing has to
  /// open a keyring to draw a list.
  static const String driveLinkedFilesKey = 'driveLinkedFiles';

  /// The `driveTokenDead` key: the pairing service has answered
  /// `pairAgain` for the stored refresh token, and only a fresh pairing
  /// fixes it (see [DriveLinkState.pairAgain]).
  ///
  /// It is stored rather than held for the run, so the screen after a restart
  /// says "pair again" straight away, instead of "linked" until the first
  /// request fails. It is not a secret and not about a file, so it is a flag
  /// here rather than a shape in the list above.
  static const String driveTokenDeadKey = 'driveTokenDead';

  /// The `drivePendingSession` key: a pairing this device started and has
  /// not finished collecting. See `DrivePairingJob` for why this is
  /// written down at all.
  ///
  /// The id is a credential while its pairing waits (see
  /// `DrivePairingSession`), but only for about ten minutes and only once. This
  /// file is private to the app, so the id is kept here with the preferences.
  /// It is never logged whole (`DrivePairingJob.logId`).
  static const String drivePendingSessionKey = 'drivePendingSession';

  /// The `viewerId` key: this install's name for its viewer, the first half of
  /// every player token (`p=<viewer>.<screen>`, see `PlayerScreen`'s
  /// `_proxyToken`). The streaming server keeps one play session per viewer, so
  /// every player screen of this install (the next episode opens a new one)
  /// continues the same session rather than starting another. Another install
  /// never shares this server: it is embedded in the app, and no other device's
  /// player uses it. The id is random, made once and kept. It is not a secret,
  /// since it names nothing but a session on the server this app talks to.
  static const String viewerIdKey = 'viewerId';

  /// The `updateCheckedAt` key: when the app last asked GitHub for its
  /// latest release, in milliseconds since the epoch (see `AppUpdates`,
  /// which asks at most once a day by itself).
  static const String updateCheckedAtKey = 'updateCheckedAt';

  /// The `updateSkippedTag` key: the release tag "Skip this version" was
  /// pressed for, which the daily look does not offer again.
  static const String updateSkippedTagKey = 'updateSkippedTag';

  bool _streamsSectioned = true;

  bool get streamsSectioned => _streamsSectioned;

  StreamOrder _streamsOrder = StreamOrder.peersPerSize;

  StreamOrder get streamsOrder => _streamsOrder;

  /// The stored labels of the resolution sections currently expanded, or null
  /// when nothing has ever been chosen (a fresh install, or a load that has not
  /// run yet). The sources list draws null and an empty set the same way, with
  /// every section collapsed, but they are different stored values. Once a
  /// viewer has collapsed everything on purpose, that empty set has to keep
  /// reading back as "on purpose", across a restart too, and never fall through
  /// to some other default.
  Set<String>? get openStreamSections => _openStreamSections;
  Set<String>? _openStreamSections;

  /// The stored labels of the addon groups currently expanded, or null
  /// when nothing has ever been chosen. Null and an empty set are drawn
  /// the same (every group shut) and stored differently, for the same
  /// reason [openStreamSections] keeps them apart: an empty set is the
  /// viewer's own "close everything" and has to read back as one.
  Set<String>? get openStreamAddons => _openStreamAddons;
  Set<String>? _openStreamAddons;

  BufferAhead _bufferAhead = BufferAhead.normal;

  BufferAhead get bufferAhead => _bufferAhead;

  FocusEmphasis _focusEmphasis = FocusEmphasis.standard;

  FocusEmphasis get focusEmphasis => _focusEmphasis;

  /// Whether the server may go on sharing between sessions -- see
  /// [shareWhileIdleKey], which is also where the default lives.
  bool get shareWhileIdle => _shareWhileIdle;
  bool _shareWhileIdle = true;

  /// Whether the log is verbose -- see [verboseDiagnosticsKey].
  bool get verboseDiagnostics => _verboseDiagnostics;
  bool _verboseDiagnostics = false;

  /// Whether a film may go straight to the display -- see [directVideoKey].
  bool get directVideo => _directVideo;
  bool _directVideo = false;

  SubtitleSyncMemory _subtitleSync = SubtitleSyncMemory.empty;

  SubtitleSyncMemory get subtitleSync => _subtitleSync;

  SubtitlePickMemory _subtitlePicks = SubtitlePickMemory.empty;

  SubtitlePickMemory get subtitlePicks => _subtitlePicks;

  DetailsVisitMemory _detailsVisits = DetailsVisitMemory.empty;

  LocalMediaFiles _localMedia = LocalMediaFiles.empty;

  /// The videos on this device -- see [localMediaKey].
  LocalMediaFiles get localMedia => _localMedia;

  List<String> _localFolders = const [];

  /// The folders a desktop looks in -- see [localFoldersKey].
  List<String> get localFolders => _localFolders;

  Map<String, String> _localFolderBookmarks = const {};

  /// macOS's way back into each folder -- see [localFolderBookmarksKey].
  Map<String, String> get localFolderBookmarks => _localFolderBookmarks;

  /// Where each title's details screen was left -- see [detailsVisitsKey].
  DetailsVisitMemory get detailsVisits => _detailsVisits;

  FacesByAccount _facesByAccount = FacesByAccount.empty;

  /// The Stremio user id signed in now, or null; set by the app from
  /// `ctx`, never stored. Decides whose faces are shown and written.
  String? _facesOwner;
  String? get facesOwner => _facesOwner;

  /// [faces] as last worked out, so a read is free.
  Faces _faces = Faces.empty;

  /// Every account's faces on this device ([facesKey]).
  FacesByAccount get facesByAccount => _facesByAccount;

  ShowEpisodesMemory _showEpisodes = ShowEpisodesMemory.empty;

  /// The episode lists the For you row has asked for ([showEpisodesKey]).
  ShowEpisodesMemory get showEpisodes => _showEpisodes;

  Map<String, dynamic>? _forYou;

  /// The For you row as last worked out ([forYouKey]); null for never.
  Map<String, dynamic>? get forYou => _forYou;

  /// What the viewer said about titles, as shown to whoever is signed in
  /// ([FacesByAccount.shownFor]): their marks and the signed-out ones.
  Faces get faces => _faces;

  SimilarMemory _similarSuggestions = SimilarMemory.empty;

  SimilarMemory get similarSuggestions => _similarSuggestions;

  TitleRatingsMemory _titleRatings = TitleRatingsMemory.empty;

  /// The scores remembered per title -- see [titleRatingsKey].
  TitleRatingsMemory get titleRatings => _titleRatings;

  /// Which Drive files are linked -- see [driveLinkedFilesKey]. Read
  /// straight out of memory, so a screen may build from it.
  LinkedDriveFiles get driveLinkedFiles => _driveLinkedFiles;
  LinkedDriveFiles _driveLinkedFiles = LinkedDriveFiles.empty;

  /// Whether the stored refresh token has been rejected -- see
  /// [driveTokenDeadKey]. False on a fresh install, and false again the
  /// moment a new pairing stores a token.
  bool get driveTokenDead => _driveTokenDead;

  String? _drivePendingSession;

  /// See [viewerIdKey]. When the file holds none, it is made and written on
  /// first use. What [load] finds replaces it only if nothing has asked for it
  /// yet.
  String get viewerId {
    if (!_viewerIdKept) {
      _viewerIdKept = true;
      unawaited(_write(viewerIdKey, _viewerId));
    }
    return _viewerId;
  }

  String _viewerId = _newViewerId();
  bool _viewerIdKept = false;

  /// Sixteen lowercase hex digits from a secure source: no `.`, so the
  /// token's screen number is always what follows the last one.
  static String _newViewerId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 8; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  static final RegExp _viewerIdShape = RegExp(r'^[0-9a-z]{1,64}$');

  /// When the latest release was last asked for -- see
  /// [updateCheckedAtKey]. Null when it never has been.
  DateTime? get updateCheckedAt => _updateCheckedAt;
  DateTime? _updateCheckedAt;

  /// The release the viewer skipped -- see [updateSkippedTagKey].
  String? get updateSkippedTag => _updateSkippedTag;
  String? _updateSkippedTag;

  /// See [drivePendingSessionKey]. Null when nothing is outstanding, which
  /// is the ordinary state.
  String? get drivePendingSession => _drivePendingSession;
  bool _driveTokenDead = false;

  /// Reads every stored preference. It is called once at start-up and not
  /// waited for: `XtremioApp` builds its first screens beside it, so a
  /// preference can be set while the read is out.
  ///
  /// **A value set during the load wins over the stored one**, which is older
  /// by definition. The keys written meanwhile ([_setWhileLoading]) are left
  /// out of what is read. For those keys, a value whose absence reads as the
  /// default is not read at all, since that absence would put the default over
  /// what was just set.
  Future<void> load() async {
    final client = this.client;
    if (client == null) return;
    final Map<String, dynamic> fetched;
    final written = _setWhileLoading = <String>{};
    try {
      fetched = await client.getAll();
    } catch (error) {
      // Preferences are conveniences: a failure here is a run with the
      // defaults, never a failure to start.
      if (kDebugMode) debugPrint('preferences unavailable: $error');
      return;
    } finally {
      _setWhileLoading = null;
    }
    final stored = {
      for (final entry in fetched.entries)
        if (!written.contains(entry.key)) entry.key: entry.value,
    };
    bool loaded(String key) => !written.contains(key);
    var changed = false;
    final sectioned = stored[streamsSectionedKey];
    if (!loaded(streamsSectionedKey)) {
      // Set during the load, so neither name is read.
    } else if (sectioned is bool) {
      if (sectioned != _streamsSectioned) {
        _streamsSectioned = sectioned;
        changed = true;
      }
    } else {
      // No choice under the current name: fall back to the legacy key
      // (see [legacyStreamsFlatKey]), read once and never written back.
      final legacy = stored[legacyStreamsFlatKey];
      if (legacy is bool && legacy != _streamsSectioned) {
        _streamsSectioned = legacy;
        changed = true;
      }
    }
    // An unparseable value -- a name a newer build wrote, a number -- reads
    // as "not set", which is the default, not a failure.
    final order = StreamOrder.parse(stored[streamsOrderKey]);
    if (order != null && order != _streamsOrder) {
      _streamsOrder = order;
      changed = true;
    }
    final openSections = stored[openStreamSectionsKey];
    if (openSections is List) {
      final parsed = <String>{
        for (final entry in openSections)
          if (entry is String) entry,
      };
      if (!setEquals(parsed, _openStreamSections)) {
        _openStreamSections = parsed;
        changed = true;
      }
    }
    final openAddons = stored[openStreamAddonsKey];
    if (openAddons is List) {
      final parsed = <String>{
        for (final entry in openAddons)
          if (entry is String) entry,
      };
      if (!setEquals(parsed, _openStreamAddons)) {
        _openStreamAddons = parsed;
        changed = true;
      }
    }
    final buffer = BufferAhead.parse(stored[bufferAheadKey]);
    if (buffer != null && buffer != _bufferAhead) {
      _bufferAhead = buffer;
      changed = true;
    }
    final emphasis = FocusEmphasis.parse(stored[focusEmphasisKey]);
    if (emphasis != null && emphasis != _focusEmphasis) {
      _focusEmphasis = emphasis;
      changed = true;
    }
    final shareWhileIdle = stored[shareWhileIdleKey];
    if (shareWhileIdle is bool && shareWhileIdle != _shareWhileIdle) {
      _shareWhileIdle = shareWhileIdle;
      changed = true;
    }
    final verbose = stored[verboseDiagnosticsKey];
    if (verbose is bool && verbose != _verboseDiagnostics) {
      _verboseDiagnostics = verbose;
      changed = true;
    }
    final directVideo = stored[directVideoKey];
    if (directVideo is bool && directVideo != _directVideo) {
      _directVideo = directVideo;
      changed = true;
    }
    // Rows this build cannot read are dropped rather than failing the
    // load; an adjustment forgotten is the failure this whole store is
    // built to accept.
    if (loaded(subtitleSyncKey)) {
      final sync = SubtitleSyncMemory.fromJson(stored[subtitleSyncKey]);
      if (sync != _subtitleSync) {
        _subtitleSync = sync;
        changed = true;
      }
    }
    if (loaded(subtitlePicksKey)) {
      final picks = SubtitlePickMemory.fromJson(stored[subtitlePicksKey]);
      if (picks != _subtitlePicks) {
        _subtitlePicks = picks;
        changed = true;
      }
    }
    if (loaded(localMediaKey)) {
      final media = LocalMediaFiles.fromJson(stored[localMediaKey]);
      if (media != _localMedia) {
        _localMedia = media;
        changed = true;
      }
    }
    if (loaded(localFoldersKey)) {
      final raw = stored[localFoldersKey];
      final folders = [
        if (raw is List)
          for (final folder in raw)
            if (folder is String && folder.trim().isNotEmpty) folder,
      ];
      if (!listEquals(folders, _localFolders)) {
        _localFolders = folders;
        changed = true;
      }
    }
    if (loaded(localFolderBookmarksKey)) {
      final raw = stored[localFolderBookmarksKey];
      final bookmarks = <String, String>{
        if (raw is Map)
          for (final MapEntry(:key, :value) in raw.entries)
            if (key is String && value is String && value.isNotEmpty)
              key: value,
      };
      if (!mapEquals(bookmarks, _localFolderBookmarks)) {
        _localFolderBookmarks = bookmarks;
        changed = true;
      }
    }
    if (loaded(detailsVisitsKey)) {
      final visits = DetailsVisitMemory.fromJson(stored[detailsVisitsKey]);
      if (visits != _detailsVisits) {
        _detailsVisits = visits;
        changed = true;
      }
    }
    if (loaded(similarSuggestionsKey)) {
      final similar = SimilarMemory.fromJson(stored[similarSuggestionsKey]);
      if (similar != _similarSuggestions) {
        _similarSuggestions = similar;
        changed = true;
      }
    }
    if (loaded(facesKey)) {
      final faces = FacesByAccount.fromJson(stored[facesKey]);
      if (faces != _facesByAccount) {
        _facesByAccount = faces;
        _faces = faces.shownFor(_facesOwner);
        changed = true;
      }
    }
    if (loaded(showEpisodesKey)) {
      _showEpisodes = ShowEpisodesMemory.fromJson(stored[showEpisodesKey]);
    }
    if (loaded(forYouKey)) {
      final forYou = stored[forYouKey];
      if (forYou is Map<String, dynamic>) _forYou = forYou;
    }
    if (loaded(titleRatingsKey)) {
      final ratings = TitleRatingsMemory.fromJson(stored[titleRatingsKey]);
      if (ratings != _titleRatings) {
        _titleRatings = ratings;
        changed = true;
      }
    }
    if (loaded(driveLinkedFilesKey)) {
      final linked = LinkedDriveFiles.fromJson(stored[driveLinkedFilesKey]);
      if (linked != _driveLinkedFiles) {
        _driveLinkedFiles = linked;
        changed = true;
      }
    }
    final tokenDead = stored[driveTokenDeadKey];
    if (tokenDead is bool && tokenDead != _driveTokenDead) {
      _driveTokenDead = tokenDead;
      changed = true;
    }
    if (loaded(drivePendingSessionKey)) {
      final pending = stored[drivePendingSessionKey];
      final pendingSession = pending is String && pending.isNotEmpty
          ? pending
          : null;
      if (pendingSession != _drivePendingSession) {
        _drivePendingSession = pendingSession;
        changed = true;
      }
    }
    if (loaded(updateCheckedAtKey)) {
      final at = stored[updateCheckedAtKey];
      if (at is int) {
        _updateCheckedAt = DateTime.fromMillisecondsSinceEpoch(at);
      }
    }
    if (loaded(updateSkippedTagKey)) {
      final tag = stored[updateSkippedTagKey];
      if (tag is String && tag.isNotEmpty) _updateSkippedTag = tag;
    }
    final storedViewer = stored[viewerIdKey];
    if (!_viewerIdKept &&
        storedViewer is String &&
        _viewerIdShape.hasMatch(storedViewer)) {
      _viewerId = storedViewer;
      _viewerIdKept = true;
    }
    if (changed) notifyListeners();
    // After the values are in memory, because nothing above waits on it:
    // a removal that fails is tried again at the next start, and the
    // value it failed to remove was not being read anyway.
    for (final key in retiredKeys) {
      if (fetched.containsKey(key)) await _write(key, null);
    }
  }

  Future<void> setStreamsSectioned(bool value) async {
    if (_streamsSectioned == value) return;
    _streamsSectioned = value;
    notifyListeners();
    await _write(streamsSectionedKey, value);
  }

  Future<void> setStreamsOrder(StreamOrder value) async {
    if (_streamsOrder == value) return;
    _streamsOrder = value;
    notifyListeners();
    await _write(streamsOrderKey, value.stored);
  }

  Future<void> setOpenStreamSections(Set<String> value) async {
    if (setEquals(_openStreamSections, value)) return;
    _openStreamSections = value;
    notifyListeners();
    await _write(openStreamSectionsKey, value.toList());
  }

  Future<void> setOpenStreamAddons(Set<String> value) async {
    if (setEquals(_openStreamAddons, value)) return;
    _openStreamAddons = value;
    notifyListeners();
    await _write(openStreamAddonsKey, value.toList());
  }

  Future<void> setBufferAhead(BufferAhead value) async {
    if (_bufferAhead == value) return;
    _bufferAhead = value;
    notifyListeners();
    await _write(bufferAheadKey, value.stored);
  }

  Future<void> setFocusEmphasis(FocusEmphasis value) async {
    if (_focusEmphasis == value) return;
    _focusEmphasis = value;
    notifyListeners();
    await _write(focusEmphasisKey, value.stored);
  }

  Future<void> setShareWhileIdle(bool value) async {
    if (_shareWhileIdle == value) return;
    _shareWhileIdle = value;
    notifyListeners();
    await _write(shareWhileIdleKey, value);
  }

  Future<void> setVerboseDiagnostics(bool value) async {
    if (_verboseDiagnostics == value) return;
    _verboseDiagnostics = value;
    notifyListeners();
    await _write(verboseDiagnosticsKey, value);
  }

  Future<void> setDirectVideo(bool value) async {
    if (_directVideo == value) return;
    _directVideo = value;
    notifyListeners();
    await _write(directVideoKey, value);
  }

  /// Stores [value], or removes the key entirely once nothing is
  /// remembered -- an empty list would be a value that says the same
  /// thing in more bytes.
  Future<void> setSubtitleSync(SubtitleSyncMemory value) async {
    if (_subtitleSync == value) return;
    _subtitleSync = value;
    notifyListeners();
    await _write(
      subtitleSyncKey,
      value.entries.isEmpty ? null : value.toJson(),
    );
  }

  /// Stores [value], or removes the key entirely once nothing is
  /// remembered -- for the same reason [setSubtitleSync] does.
  Future<void> setSubtitlePicks(SubtitlePickMemory value) async {
    if (_subtitlePicks == value) return;
    _subtitlePicks = value;
    notifyListeners();
    await _write(
      subtitlePicksKey,
      value == SubtitlePickMemory.empty ? null : value.toJson(),
    );
  }

  /// Stores [value], or removes the key once nothing is on this device.
  ///
  /// **Tells no listener**, for the same reason as [setDetailsVisits]. Matching
  /// writes once per file, and a phone holds hundreds. What draws from the
  /// record listens to `LocalMedia`, which says when it changed.
  Future<void> setLocalMedia(LocalMediaFiles value) async {
    if (_localMedia == value) return;
    _localMedia = value;
    await _write(
      localMediaKey,
      value == LocalMediaFiles.empty ? null : value.toJson(),
    );
  }

  /// Stores the folders a desktop looks for videos in; the Settings list
  /// draws from them, so this one does notify.
  Future<void> setLocalFolders(List<String> folders) async {
    if (listEquals(folders, _localFolders)) return;
    _localFolders = List.unmodifiable(folders);
    notifyListeners();
    await _write(localFoldersKey, folders.isEmpty ? null : folders);
  }

  /// Stores the macOS bookmarks of the chosen folders. Nothing draws from
  /// them, so this tells no listener.
  Future<void> setLocalFolderBookmarks(Map<String, String> bookmarks) async {
    if (mapEquals(bookmarks, _localFolderBookmarks)) return;
    _localFolderBookmarks = Map.unmodifiable(bookmarks);
    await _write(localFolderBookmarksKey, bookmarks.isEmpty ? null : bookmarks);
  }

  /// Stores [value], or removes the key entirely once nothing is
  /// remembered -- for the same reason [setSubtitleSync] does.
  ///
  /// **Tells no listener.** Nothing is drawn from this: a details screen reads
  /// its title's row once, when it opens. Notifying would rebuild every screen
  /// that reads the preferences each time a viewer stopped on a season. It
  /// would also make the write impossible from a screen's `dispose`, where the
  /// last one is made, since a rebuild cannot be asked for while the tree is
  /// taking a screen down.
  Future<void> setDetailsVisits(DetailsVisitMemory value) async {
    if (_detailsVisits == value) return;
    _detailsVisits = value;
    await _write(
      detailsVisitsKey,
      value == DetailsVisitMemory.empty ? null : value.toJson(),
    );
  }

  /// Stores what the server has answered, or removes the key once nothing is
  /// remembered -- for the same reason [setSubtitleSync] does.
  Future<void> setSimilarSuggestions(SimilarMemory value) async {
    if (_similarSuggestions == value) return;
    _similarSuggestions = value;
    notifyListeners();
    await _write(
      similarSuggestionsKey,
      value.entries.isEmpty ? null : value.toJson(),
    );
  }

  /// Who is signed in, for the faces ([facesOwner]). Tells every listener
  /// when it changes what is shown.
  void setFacesOwner(String? owner) {
    if (owner == _facesOwner) return;
    _facesOwner = owner;
    final shown = _facesByAccount.shownFor(owner);
    if (shown == _faces) return;
    _faces = shown;
    notifyListeners();
  }

  /// Marks [id] with [face] (null takes it off) at [at], under whoever is
  /// signed in now -- or nobody.
  Future<void> markFace(String id, Face? face, DateTime at) => setFacesOf(
    _facesOwner,
    _facesByAccount.of(_facesOwner).marking(id, face, at),
  );

  /// Replaces [owner]'s own marks (null: nobody's) and writes the lot, or
  /// removes the key once no account has any. Tells every listener: a
  /// details screen draws the faces and the For you row is ranked by them.
  Future<void> setFacesOf(String? owner, Faces value) async {
    final next = _facesByAccount.withOwner(owner, value);
    if (next == _facesByAccount) return;
    _facesByAccount = next;
    _faces = next.shownFor(_facesOwner);
    notifyListeners();
    await _write(facesKey, next.isEmpty ? null : next.toJson());
  }

  /// [setFacesOf] for whoever is signed in now.
  Future<void> setFaces(Faces value) => setFacesOf(_facesOwner, value);

  /// Stores the episode lists. Tells no listener: the row that asked has
  /// them in hand.
  Future<void> setShowEpisodes(ShowEpisodesMemory value) async {
    _showEpisodes = value;
    await _write(showEpisodesKey, value.shows.isEmpty ? null : value.toJson());
  }

  /// Stores the For you row as worked out. Tells no listener, for the same
  /// reason.
  Future<void> setForYou(Map<String, dynamic>? value) async {
    _forYou = value;
    await _write(forYouKey, value);
  }

  /// Stores the remembered scores, or removes the key once nothing is.
  ///
  /// Tells no listener, like [setDetailsVisits]. The screen that asked already
  /// has the scores in hand, and every other screen reading the preferences
  /// would rebuild for a value none of them draws.
  Future<void> setTitleRatings(TitleRatingsMemory value) async {
    if (_titleRatings == value) return;
    _titleRatings = value;
    await _write(
      titleRatingsKey,
      value.entries.isEmpty ? null : value.toJson(),
    );
  }

  /// Stores which files are linked, or removes the key once nothing is --
  /// for the same reason [setSubtitleSync] does.
  ///
  /// Written by [DriveAccount], not by a screen. The list and the token are two
  /// halves of one fact, and a screen that moved one without the other would
  /// write a list of files nothing can open.
  Future<void> setDriveLinkedFiles(LinkedDriveFiles value) async {
    if (_driveLinkedFiles == value) return;
    _driveLinkedFiles = value;
    notifyListeners();
    await _write(driveLinkedFilesKey, value.isEmpty ? null : value.toJson());
  }

  /// Records that the refresh token has been rejected, or that a fresh one has
  /// replaced it. Written by [DriveAccount] too, for the same reason.
  Future<void> setDriveTokenDead(bool value) async {
    if (_driveTokenDead == value) return;
    _driveTokenDead = value;
    notifyListeners();
    await _write(driveTokenDeadKey, value ? true : null);
  }

  Future<void> setDrivePendingSession(String? value) async {
    if (_drivePendingSession == value) return;
    _drivePendingSession = value;
    notifyListeners();
    await _write(drivePendingSessionKey, value);
  }

  /// Records when the latest release was asked for. **Tells no listener**:
  /// nothing is drawn from it.
  Future<void> setUpdateCheckedAt(DateTime value) async {
    _updateCheckedAt = value;
    await _write(updateCheckedAtKey, value.millisecondsSinceEpoch);
  }

  /// Records the release "Skip this version" was pressed for. Tells no
  /// listener either, for the same reason.
  Future<void> setUpdateSkippedTag(String? value) async {
    if (_updateSkippedTag == value) return;
    _updateSkippedTag = value;
    await _write(updateSkippedTagKey, value);
  }

  /// The keys written since [load] asked for the stored values, while it
  /// is waiting for them; null otherwise.
  Set<String>? _setWhileLoading;

  /// The last write asked for, which the next one waits on. One chain serves
  /// every key. Each `prefsSet` is its own FFI call on a worker pool, so two
  /// writes started together (the pairing job's `set(id)` and then `set(null)`)
  /// could otherwise land in either order and leave the file holding the older
  /// value. It never completes with an error ([_write] catches its own).
  Future<void> _writes = Future<void>.value();

  Future<void> _write(String key, Object? value) {
    final client = this.client;
    if (client == null) return Future<void>.value();
    // At the call, not when the write gets its turn: [load] asks which keys
    // were set while it waited, and a queued write is one of them.
    _setWhileLoading?.add(key);
    return _writes = _writes.then((_) async {
      try {
        await client.set(key, value);
      } catch (error) {
        if (kDebugMode) debugPrint('preference $key not stored: $error');
      }
    });
  }
}

/// Hands [AppPrefs] down the tree. An [InheritedNotifier], so a screen that
/// reads a preference rebuilds when it is changed anywhere else.
class PrefsScope extends InheritedNotifier<AppPrefs> {
  const PrefsScope({super.key, required AppPrefs prefs, required super.child})
    : super(notifier: prefs);

  static AppPrefs of(BuildContext context) {
    final prefs = maybeOf(context);
    assert(prefs != null, 'No PrefsScope above this widget');
    return prefs!;
  }

  static AppPrefs? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PrefsScope>()?.notifier;
}
