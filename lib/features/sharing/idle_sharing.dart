import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/core.dart';

/// Whether the embedded server may go on sharing a title after the viewer
/// has finished watching it: what the choice means, what it defaults to and
/// where the answer goes.
///
/// **What the server already offers, and what the app adds.** The server
/// has had this setting all along: `seedingEnabled` in its `ServerSettings`
/// (`server/src/routes/system.rs`, "when true, torrents continue seeding
/// after download completes"), true by default, merged and persisted by
/// `POST /settings` -- which the app reaches as
/// `ServerClient.updateSettings`, over `server_update_settings`, the same
/// function that route runs. So nothing new was needed on the wire and
/// nothing here speaks HTTP: what was missing was somebody deciding what to
/// put in it, which is [IdleSharingPolicy] below. A title kept offline is
/// not governed by it either way -- a pinned download keeps downloading
/// whatever this says, and stops being shared when it is unpinned like
/// anything else.
///
/// **It is on everywhere, and the switch is the whole of the control.**
/// There used to be a default per device -- a television shares, a phone
/// does not -- on the reasoning that a box in a wall socket on the house's
/// line costs nobody anything while a phone spends a battery and a bill.
/// What that reasoning is really about is a cost the owner cannot see, and
/// the answer to that is to *show* it rather than to guess at it: a device
/// this app has never met is not a thing to have opinions about. Keeping a
/// torrent in the swarm is the polite way to have taken the film in the
/// first place, so it happens by default, and one press stops it.
///
/// **Nothing here asks what the connection costs, and nothing should.**
/// There was a term for it: a `ConnectivityManager` watcher behind an event
/// channel that reported whether this device's link was billed by the byte,
/// and a rule here that refused to seed on a metered one whatever the switch
/// said. It is gone, and the reason it cannot come back in that shape is
/// that only Android could answer it: Linux, macOS and Windows -- all
/// first-class targets -- resolved to "unmetered" unconditionally, so a
/// laptop tethered to a phone seeded over mobile data under a tile promising
/// it never would. A rule that is right on one platform and lying on three
/// is worse than no rule, because the tile is then the thing that is wrong.
/// What is left is a switch that means what it says. On a phone that means
/// the data is spent by the time anybody thinks about it, which is accepted
/// rather than overlooked.
///
/// **Charging is deliberately *not* a term either**, though it was
/// considered: it is invisible, so a switch somebody turned on would do
/// nothing for most of the day with nothing on screen saying why, which is
/// the same fault as a button that is drawn and dead; and it changes several
/// times a day, so the server's policy would flap on every plug and unplug.
class IdleSharing {
  const IdleSharing._();

  /// The settings key on the server, spelled its way. The Rust field is
  /// `seeding_enabled`; this is its `serde` rename, which is what
  /// `POST /settings` reads and therefore what the patch has to say.
  static const String seedingEnabledKey = 'seedingEnabled';

  /// What the switch is called in Settings.
  static const String title = 'Share while idle';

  /// What turning it on buys, on the tile rather than in a help page --
  /// and what it buys is a few minutes, which is what this says.
  ///
  /// It used to promise "until the next stream starts", and the pinned
  /// server does no such thing: nothing stops sharing when the next stream
  /// begins, and an engine nothing is streaming is removed once it has been
  /// idle for `INACTIVE_TORRENT_REMOVE_TIMEOUT` -- 300 seconds, swept every
  /// 15, whatever `seedingEnabled` says (`enginefs/src/lib.rs` at the rev
  /// `rust/Cargo.toml` pins; a pinned download is the exception and is
  /// exempt from the sweep). What the setting really changes is the few
  /// minutes before that: with it off the torrent is paused
  /// `INACTIVE_TORRENT_PAUSE_GRACE` -- 15 seconds -- after the last stream
  /// ends, and with it on those minutes are spent seeding.
  ///
  /// A longer lifecycle is the server's keep/share policy, which is being
  /// built there and is not in the pinned rev. **This sentence describes
  /// what the app causes today and changes when that lands**, because a
  /// tile describing a future is the same defect as a comment describing an
  /// intention.
  static const String description =
      'Keeps uploading what you watched to other people for about five '
      'minutes after playback stops.';

  /// The gentler of the two stops the status light offers, and what it
  /// costs: nothing is written down, so the next start of the app shares
  /// again. It is the run that ends it and not a session, because a run is
  /// a thing this app has -- [IdleSharingPolicy] lives exactly as long as
  /// the process, and the server it is telling goes down with it -- where a
  /// "session" would be a timer somebody had to choose the length of.
  static const String pauseTitle = 'Not now';
  static const String pauseDescription =
      'Stops sharing until you next start Xtremio. The setting stays on.';

  /// The other stop: the switch below, from the other end of the app.
  static const String stopTitle = 'Stop sharing';
  static const String stopDescription =
      'Turns this setting off for good, the same switch as in Settings.';

  /// What the settings tile adds while a "Not now" is in force. Without it
  /// the tile would show the switch on while nothing is being shared, which
  /// is the exact fault -- a tile describing something the app is not
  /// doing -- that the rest of this class was rewritten to remove.
  ///
  /// It is only ever drawn under a switch that is *on*, and that is what
  /// makes it true: a pause ends when the switch is turned off
  /// ([IdleSharingPolicy]), so the resumption this promises is the one the
  /// setting will still be asking for at the next start.
  static const String pausedNote = 'Paused until you next start Xtremio.';
}

/// Keeps the embedded server's `seedingEnabled` equal to
/// [AppPrefs.shareWhileIdle], for as long as the app is running.
///
/// One of these for the whole app, built by `XtremioApp`, because there is
/// one server and one answer. It reads one thing -- the viewer's choice
/// ([AppPrefs], which notifies) -- and writes one settings key. That is
/// thin enough to look like a wrapper and is not: what it is for is that
/// nothing else in the app writes `seedingEnabled`, so the server's belief
/// has one author however many screens change the preference.
///
/// **It pushes as soon as it starts.** The server's own default is `true`
/// and so is the preference's, so this agrees with the server on a fresh
/// install -- but a viewer who has turned it off has to be told before
/// anything can be shared, and [start] is called after the preferences have
/// loaded, so the first thing the server hears is their answer and not the
/// default they overrode.
///
/// **It pushes only changes, and one at a time.** Nothing is written when
/// the answer is the answer already sent, so a preference that notifies for
/// some other key costs nothing; and the writes are chained rather than
/// fired off, because two settings calls in flight land on the bridge's
/// worker pool in no particular order and the loser decides what the server
/// ends up believing.
///
/// **A "Not now" is this same policy with a shorter memory.** The status
/// light's popup calls [pauseUntilRestart], which holds the answer at false
/// for the rest of the run without writing anything down, so the setting
/// still says what the viewer chose and the next start of the app shares
/// again. It is not a second author of `seedingEnabled` -- there is still
/// exactly one -- and it is not a third state in the preference either,
/// because it must not survive the process that granted it. Nor does it
/// survive the switch moving: a pause is what a switch that is on looks
/// like this run, and either press of the switch is a newer answer than
/// the one the popup took.
///
/// **It notifies when that pause goes on or off**, and that is the only
/// thing it says anything about: what the server was told is the server's
/// business, but the pause is a state the settings tile draws, and the
/// popup that grants one is drawn over the very screen that tile is on. A
/// preference notifies its own listeners already, so nothing here repeats
/// the switch.
class IdleSharingPolicy extends ChangeNotifier {
  IdleSharingPolicy({required this.prefs, required this.server})
    : _wasAllowed = prefs.shareWhileIdle;

  /// The viewer's choice, and what tells this when it changes.
  final AppPrefs prefs;

  /// Where the answer goes: one key of the embedded server's settings.
  final ServerSettingsWriter server;

  /// What the server was last told, or null when it has been told nothing
  /// (or when the telling failed, so the next change tries again).
  bool? _sent;

  /// A "Not now" from the status light's popup: sharing is off for the rest
  /// of this run, and nothing is written down, so the next start shares
  /// again. See [pauseUntilRestart].
  bool _paused = false;

  /// What the preference said when it was last read, so that turning the
  /// switch *on* can be told from its having been on all along.
  bool _wasAllowed;

  /// The writes so far, chained so the server is never told two things at
  /// once. Also what a test waits on to see what was written.
  Future<void> _writes = Future<void>.value();

  bool _stopped = false;

  /// Starts watching. Safe to call after [dispose]; it does nothing then.
  void start() {
    if (_stopped) return;
    prefs.addListener(_reconsider);
    _reconsider();
  }

  /// Everything written so far has landed. For tests; nothing in the app
  /// waits on this policy.
  @visibleForTesting
  Future<void> get settled => _writes;

  /// Stops the sharing for the rest of this run, leaving the preference
  /// alone: what the status light's "Not now" does.
  ///
  /// The server is told at once, through the one path that tells it
  /// anything. Nothing persists it, so the next start of the app pushes the
  /// preference again and sharing resumes -- which is what the popup says
  /// it does, and the whole difference between this and the switch.
  void pauseUntilRestart() {
    if (_paused || _stopped) return;
    _paused = true;
    _reconsider();
    notifyListeners();
  }

  /// A "Not now" is in force, which it can only be while the setting is
  /// on. What reads it is the settings tile, which must not show a switch
  /// that is on over a run in which nothing is being shared -- and which
  /// is on screen when the popup that grants one is, so this notifies when
  /// it changes.
  bool get pausedForRun => _paused;

  void _reconsider() {
    if (_stopped) return;
    // A pause is a state of a switch that is *on*: it holds back a sharing
    // the setting still allows, and it is over the moment the switch says
    // anything of its own. Turning it on is a fresh instruction to share,
    // and the alternative is a switch the viewer has just pressed that does
    // nothing until the app is restarted. Turning it off ends the pause
    // too, because the switch is the longer of the two stops and saying
    // "paused until you next start Xtremio" under it would promise a
    // resumption that is never coming.
    final wanted = prefs.shareWhileIdle;
    final lifted = wanted != _wasAllowed && _paused;
    if (lifted) _paused = false;
    _wasAllowed = wanted;
    final allowed = wanted && !_paused;
    if (lifted) notifyListeners();
    if (allowed == _sent) return;
    _sent = allowed;
    _writes = _writes.then((_) => _push(allowed));
  }

  Future<void> _push(bool allowed) async {
    try {
      await server.updateSettings({IdleSharing.seedingEnabledKey: allowed});
    } catch (error) {
      // A server that is not up yet, or that refused: the policy is not
      // recorded as sent, so the next press writes it again. Nothing
      // retries on its own -- there is no deadline here, and a timer would
      // be a second thing to get wrong.
      if (kDebugMode) debugPrint('sharing policy not applied: $error');
      if (_sent == allowed) _sent = null;
    }
  }

  /// Stops watching. The server is left holding whatever it was last told,
  /// which is right: the app going away is what ends the sharing, and it
  /// ends it by taking the server with it.
  ///
  /// Stopping twice is stopping, as starting after a stop is nothing:
  /// [ChangeNotifier.dispose] refuses a second call, and the run this
  /// object is the length of can be ended by the app and by whatever else
  /// is holding it.
  @override
  void dispose() {
    if (_stopped) return;
    _stopped = true;
    prefs.removeListener(_reconsider);
    super.dispose();
  }
}
