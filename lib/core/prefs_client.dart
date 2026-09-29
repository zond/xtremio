import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../src/rust/api/prefs.dart' as rust;
import 'buffer_ahead.dart';
import 'details_visits.dart';
import 'drive_link.dart';
import 'local_media_files.dart';
import 'focus_emphasis.dart';
import 'similar_memory.dart';
import 'stream_order.dart';
import 'subtitle_picks.dart';
import 'subtitle_sync.dart';

/// The app's own preferences, over the Rust side's small JSON file
/// (`rust/src/prefs.rs`, `<storage_dir>/xtremio_prefs.json`).
///
/// These are the *client's* choices — how a list is laid out, which view a
/// screen comes up in — and deliberately not stremio-core `Settings`
/// fields: that struct is the engine's, it is synced to the account, and
/// adding to it would mean forking the core. They are equally deliberately
/// not a Dart preferences package: the storage directory is already ours
/// and already writes atomically.
///
/// An interface so widget tests can hand [AppPrefs] a map instead of
/// reaching FFI, the way `DiagnosticsClient` works for Diagnostics.
abstract interface class PrefsClient {
  /// Every preference that has been set. An empty map means none has been —
  /// a missing, unreadable or non-object file all read that way, since a
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
/// [load] failing (nothing has pointed storage anywhere yet, no Rust
/// library under a test) leaves the defaults, and a failed write leaves the
/// value in memory: the choice holds for this run and simply does not
/// survive a restart, which is a better answer than a control that snaps
/// back under the user's finger.
class AppPrefs extends ChangeNotifier {
  AppPrefs({this.client});

  /// One that persists nothing, for a screen mounted with no [PrefsScope]
  /// above it (a widget test that does not care where the choice goes).
  AppPrefs.inMemory() : this();

  /// Where the values are read from and written to; null persists nothing.
  final PrefsClient? client;

  /// The `streamsSectioned` key: whether the Details screen lists every
  /// addon's streams together, cut into a collapsible section per
  /// resolution, instead of one section per addon. True — sectioned — is
  /// the default: a fresh install has never chosen, and a fresh install is
  /// what this flag now defaults to showing.
  ///
  /// [load] falls back to [legacyStreamsFlatKey] when this key is unset, so
  /// an install that chose under the old name keeps its choice.
  static const String streamsSectionedKey = 'streamsSectioned';

  /// The boolean an install from before the rename may still have under
  /// its old name, `streamsFlat`. [load] reads it only when
  /// [streamsSectionedKey] itself is unset, and nothing here ever writes
  /// to it again — the first toggle after an upgrade moves the choice to
  /// the new key and the old one is left stale.
  static const String legacyStreamsFlatKey = 'streamsFlat';

  /// The `streamsOrder` key: what order the streams inside one resolution
  /// section of that list are in (see [StreamOrder]). Global for the same
  /// reason [streamsSectionedKey] is — an order chosen on one title is the
  /// order the next title comes up in.
  static const String streamsOrderKey = 'streamsOrder';

  /// The `openStreamSections` key: which resolution sections of the
  /// sectioned sources list are expanded, as a list of each section's
  /// stored label (a resolution's own [StreamResolution.label], or
  /// `'unknown'` for the section nothing could be read a resolution from —
  /// see `_sectionStorageLabel` in `meta_details_screen.dart`). Global and
  /// sticky the same way the layout and the order are: a section opened on
  /// one title is open on the next, and on the next restart.
  ///
  /// Every section starts collapsed until the viewer opens one — an empty
  /// list is a real, deliberately-chosen value ("collapse everything"),
  /// not "nothing chosen yet", so [load] keeps that apart from a missing
  /// key the same way it does for [streamsSectionedKey]. See
  /// [openStreamSections].
  static const String openStreamSectionsKey = 'openStreamSections';

  /// The `openStreamAddons` key: which addon groups of the *grouped*
  /// sources list are expanded, as a list of each group's stored label
  /// (the addon's transport URL — see `_addonStorageLabel` in
  /// `meta_details_screen.dart`). Global and sticky exactly the way
  /// [openStreamSectionsKey] is, and empty the same deliberate way: with
  /// nothing remembered every group is shut, on a fresh install and after
  /// the viewer has closed the last one.
  ///
  /// A key of its own rather than a share of [openStreamSectionsKey], for
  /// two reasons. An addon may be called something a resolution is also
  /// called, and one set cannot tell the two apart — the addon would open
  /// a section, or the section the addon. And they are different
  /// questions: what a viewer left open among resolutions says nothing
  /// about which addons they want open, so one layout's choice must not
  /// arrive as the other's.
  static const String openStreamAddonsKey = 'openStreamAddons';

  /// The `bufferAhead` key: how far ahead playback buffers by default (see
  /// [BufferAhead]). The player takes this unless the viewer overrides it
  /// for the playback on screen.
  static const String bufferAheadKey = 'bufferAhead';

  /// The `focusEmphasis` key: how strongly focus is marked on a television
  /// (see [FocusEmphasis]). This device's room and display, not the
  /// account's, which is why it lives here rather than in
  /// `profile.settings`.
  static const String focusEmphasisKey = 'focusEmphasis';

  /// The `shareWhileIdle` key: whether the embedded server goes on
  /// uploading to other people when nothing is playing (`IdleSharing`).
  ///
  /// **On until the viewer turns it off**, which is why it is a plain
  /// `bool` and not a `bool?`: the default is the same everywhere, so a
  /// missing key and a stored `true` mean the same thing and there is
  /// nothing left for a null to say. A stored `false` is a decision and
  /// still survives, which is all the storage ever had to do.
  static const String shareWhileIdleKey = 'shareWhileIdle';

  /// The `verboseDiagnostics` key: whether the Diagnostics log carries the
  /// streaming server's retention trace -- what its cache decided about
  /// each file and why -- and mpv's demuxer, stream and cache lines
  /// (`DiagnosticsTraceSync`, `MediaKitEngine.verboseLog`). Off by default:
  /// both are what a report is read by when playback misbehaves, and noise
  /// the rest of the time, filling the ring the report copies. This
  /// device's, like the other preferences here, since it is about what
  /// this device's log holds.
  static const String verboseDiagnosticsKey = 'verboseDiagnostics';

  /// The `subtitleSync` key: every subtitle adjustment the viewer has
  /// made that is still remembered (see [SubtitleSyncMemory]), most
  /// recent first.
  ///
  /// One key for both adjustments even though they are keyed differently
  /// -- a speed on the series and the release group, a shift on those
  /// and the video release as well -- because they are the same
  /// preference: what this viewer has already fixed. It is a list, so
  /// the recency the bound drops by is the order itself.
  static const String subtitleSyncKey = 'subtitleSync';

  /// The `subtitlePicks` key: which subtitle each show was last watched
  /// with, and how often each language has been picked at all (see
  /// [SubtitlePickMemory]).
  ///
  /// A separate key from [subtitleSyncKey] because it answers a different
  /// question. The sync memory is what the viewer *fixed* about a file's
  /// timing; this is what they *chose*, and the two are written by
  /// different hands -- the panel writes one, the menu the other -- read
  /// at different moments and forgotten independently.
  static const String subtitlePicksKey = 'subtitlePicks';

  /// The `localMedia` key: the videos on this device and what each one
  /// matched (see [LocalMediaFiles]).
  static const String localMediaKey = 'localMedia';

  /// The `localFolders` key: the folders a desktop looks for videos in,
  /// chosen in Settings. A phone or a television uses its media index and
  /// never reads this.
  static const String localFoldersKey = 'localFolders';

  /// The `detailsVisits` key: which season and episode each title's
  /// details screen was left on (see [DetailsVisitMemory]).
  static const String detailsVisitsKey = 'detailsVisits';

  /// Keys an older build wrote and this one removes on [load]:
  /// `similarApiKey`, the Gemini key a viewer once pasted so the app could
  /// ask a model itself, and `similarModel`, which model it asked.
  ///
  /// "More like this" is asked of the xtremio-xervice server now, which holds
  /// the only key there is, so neither means anything to this build. They
  /// are not merely ignored: the first is a credential, and a credential
  /// nothing reads is one that should not be lying in a file on the device
  /// -- so a load that finds either writes it away, once, and every later
  /// load finds nothing.
  static const List<String> retiredKeys = ['similarApiKey', 'similarModel'];

  /// The `similarSuggestions` key: what the server has already answered
  /// about each title (see [SimilarMemory]).
  ///
  /// Kept for the life of the install as the first of two caches: the
  /// server keeps one answer per title for everyone, and this keeps it on
  /// the device, so a title is asked of the server once per install and
  /// its row is there without a round trip every time it is opened.
  static const String similarSuggestionsKey = 'similarSuggestions';

  /// The `driveLinkedFiles` key: which Google Drive files a pairing has
  /// linked to this device (see [LinkedDriveFiles]).
  ///
  /// Here, and not in the [SecretStore] beside the refresh token, because
  /// it is not a secret: file ids and filenames are the same kind of thing
  /// as the library, and a viewer looking at this file learns nothing they
  /// could use. The token is the secret and it is the only thing kept
  /// anywhere else. Keeping the list here is also what makes the Drive
  /// screen cheap to build -- it is already in memory with the rest of the
  /// preferences, and nothing has to open a keyring to draw a list.
  static const String driveLinkedFilesKey = 'driveLinkedFiles';

  /// The `driveTokenDead` key: the pairing service has answered
  /// `pairAgain` for the stored refresh token, and only a fresh pairing
  /// fixes it (see [DriveLinkState.pairAgain]).
  ///
  /// Stored rather than held for the run, so the screen that comes up
  /// after a restart says "pair again" straight away instead of saying
  /// "linked" until the first request fails. It is not a secret and it is
  /// not about a file, so it is a flag here rather than a shape in the
  /// list above.
  static const String driveTokenDeadKey = 'driveTokenDead';

  /// The `drivePendingSession` key: a pairing this device started and has
  /// not finished collecting. See `DrivePairingJob` for why this is
  /// written down at all.
  ///
  /// The id is a credential while its pairing waits (see
  /// `DrivePairingSession`) but only for about ten minutes and only once,
  /// and this file is private to the app, so it is kept here with the
  /// preferences. It is never logged whole (`DrivePairingJob.logId`).
  static const String drivePendingSessionKey = 'drivePendingSession';

  /// The `viewerId` key: this install's name for its viewer, the first half
  /// of every player token (`p=<viewer>.<screen>`, see
  /// `PlayerScreen`'s `_proxyToken`). The streaming server keeps one play
  /// session per viewer, so every player screen of this install -- the next
  /// episode opens a new one -- continues the same session rather than
  /// starting another. (Another install never shares this server: it is
  /// embedded in the app, and no other device's player uses it.) Random,
  /// made once and kept; not a secret, since it names nothing but a session
  /// on the server this app talks to.
  static const String viewerIdKey = 'viewerId';

  bool _streamsSectioned = true;

  bool get streamsSectioned => _streamsSectioned;

  StreamOrder _streamsOrder = StreamOrder.peersPerSize;

  StreamOrder get streamsOrder => _streamsOrder;

  /// The stored labels of the resolution sections currently expanded, or
  /// null when nothing has ever been chosen — a fresh install, or a load
  /// that has not run yet. The sources list also draws null and an empty
  /// set the same way (every section collapsed), but the two are not the
  /// same stored value: once a viewer has collapsed everything on purpose,
  /// that empty set has to keep reading back as "on purpose", including
  /// across a restart, never fall through to some other default.
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

  /// Where each title's details screen was left -- see [detailsVisitsKey].
  DetailsVisitMemory get detailsVisits => _detailsVisits;

  SimilarMemory _similarSuggestions = SimilarMemory.empty;

  SimilarMemory get similarSuggestions => _similarSuggestions;

  /// Which Drive files are linked -- see [driveLinkedFilesKey]. Read
  /// straight out of memory, so a screen may build from it.
  LinkedDriveFiles get driveLinkedFiles => _driveLinkedFiles;
  LinkedDriveFiles _driveLinkedFiles = LinkedDriveFiles.empty;

  /// Whether the stored refresh token has been rejected -- see
  /// [driveTokenDeadKey]. False on a fresh install, and false again the
  /// moment a new pairing stores a token.
  bool get driveTokenDead => _driveTokenDead;

  String? _drivePendingSession;

  /// See [viewerIdKey]. Made on first use when the file holds none, and
  /// written then; what [load] finds replaces it only if nothing has asked
  /// for it yet.
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

  /// See [drivePendingSessionKey]. Null when nothing is outstanding, which
  /// is the ordinary state.
  String? get drivePendingSession => _drivePendingSession;
  bool _driveTokenDead = false;

  /// Reads every stored preference. Called once at start-up, and not
  /// waited for: `XtremioApp` builds its first screens beside it, so a
  /// preference can be set while the read is out.
  ///
  /// **A value set during the load wins over the stored one**, which is
  /// older by definition. The keys written meanwhile ([_setWhileLoading])
  /// are left out of what is read, and the values whose absence reads as
  /// the default are not read at all for them -- an absence that would
  /// otherwise put the default over what was just set.
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
  /// **Tells no listener**, for the reason [setDetailsVisits] tells none:
  /// matching writes once per file, a phone holds hundreds, and what draws
  /// from the record listens to `LocalMedia`, which says when it changed.
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

  /// Stores [value], or removes the key entirely once nothing is
  /// remembered -- for the same reason [setSubtitleSync] does.
  ///
  /// **Tells no listener.** Nothing is drawn from this: a details screen
  /// reads its title's row once, when it opens. Notifying would rebuild
  /// every screen that reads the preferences each time a viewer stopped
  /// on a season, and would make the write impossible from a screen's
  /// `dispose`, which is where the last one is made -- a rebuild cannot be
  /// asked for while the tree is taking a screen down.
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

  /// Stores which files are linked, or removes the key once nothing is --
  /// for the same reason [setSubtitleSync] does.
  ///
  /// Written by [DriveAccount] and not by a screen: the list and the token
  /// are two halves of one fact, and letting a screen move one of them
  /// without the other is how a list of files nothing can open gets
  /// written.
  Future<void> setDriveLinkedFiles(LinkedDriveFiles value) async {
    if (_driveLinkedFiles == value) return;
    _driveLinkedFiles = value;
    notifyListeners();
    await _write(driveLinkedFilesKey, value.isEmpty ? null : value.toJson());
  }

  /// Records that the refresh token has been rejected, or that a fresh one
  /// has replaced it. [DriveAccount] again, for the same reason.
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

  /// The keys written since [load] asked for the stored values, while it
  /// is waiting for them; null otherwise.
  Set<String>? _setWhileLoading;

  /// The last write asked for, which the next one waits on. One chain for
  /// every key: each `prefsSet` is its own FFI call on a worker pool, so two
  /// writes started together -- the pairing job's `set(id)` and then
  /// `set(null)` -- could otherwise land in either order and leave the file
  /// holding the older value. Never completes with an error ([_write]
  /// catches its own).
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
