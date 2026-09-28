import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/core.dart';
import '../../src/rust/api/server.dart' as rust;

/// Whether the embedded server uploads to other people while nothing is
/// playing: what the choice means, what it defaults to and where the answer
/// goes.
///
/// **What the server offers, and what the app adds.** The setting is the
/// server's: `seedingEnabled` in its `ServerSettings`
/// (`server/src/routes/system.rs`), true by default, merged and persisted by
/// `POST /settings` -- which the app reaches as
/// `ServerClient.updateSettings`, over `server_update_settings`, the same
/// function that route runs. The server uploads while a player is reading
/// and while a torrent download is on its way, whatever this says:
/// downloading is activity, not idling. What the setting governs is the
/// rest -- what was watched or downloaded before -- which on, goes on
/// being shared when nothing is happening, and off, is not. Nothing here
/// speaks HTTP: what the app adds is somebody deciding what to put in it,
/// which is [IdleSharingPolicy] below. It governs uploading and nothing
/// else: a title kept offline goes on downloading whatever this says.
///
/// **It is on everywhere, and the switch is the whole of the control.**
/// There is no per-device default: a device this app has never met is not
/// a thing to have opinions about. Keeping a torrent in the swarm is the
/// polite way to have taken the film in the first place, so it happens by
/// default, and one press stops it.
///
/// **Nothing here asks what the connection costs, and nothing should.**
/// Only Android can report whether a link is metered; Linux, macOS and
/// Windows -- all first-class targets -- resolve to "unmetered"
/// unconditionally, so a rule built on that would seed over a phone's
/// billed tether while a tile promised it never would. A rule right on one
/// platform and lying on three is worse than no rule. The switch means what
/// it says; on a phone that means the data is spent, which is accepted
/// rather than hidden.
///
/// **On a phone or a tablet the idle sharing stops while the app is in the
/// background** ([DeviceProfile.isHandheld]), and comes back when the app
/// does. Somebody who has put their phone away does not expect the app they
/// left to go on spending their data on what they watched last week, and
/// finding out it did is too bad a surprise for a switch to excuse. A
/// download they started is another matter: it is still happening, so it
/// goes on sharing while it fetches, in the background too. A television
/// and a desktop are left running on purpose, and a program there uploading
/// behind another window is what a torrent client does, so there it goes
/// on. The tile says so where it applies ([backgroundNote]).
///
/// **Charging is deliberately *not* a term either**: it is invisible, so a
/// switch somebody turned on would do nothing for most of the day with
/// nothing on screen saying why, and it changes several times a day, which
/// would flap the server's policy on every plug and unplug.
class IdleSharing {
  const IdleSharing._();

  /// The settings key on the server, spelled its way. The Rust field is
  /// `seeding_enabled`; this is its `serde` rename, which is what
  /// `POST /settings` reads and therefore what the patch has to say.
  static const String seedingEnabledKey = 'seedingEnabled';

  /// What the switch is called in Settings.
  static const String title = 'Share while idle';

  /// What turning it on buys, on the tile rather than in a help page.
  ///
  /// The server uploads while a player is reading whatever this says, and
  /// with it on goes on uploading when nothing is: `seedingEnabled`, which
  /// the server turns into the torrent session's choke, so nothing is
  /// paused and nothing stops downloading. What the tile names is therefore
  /// what is left once playback stops -- uploading, and only uploading --
  /// and where to see it happen.
  ///
  /// **This sentence must say what the server actually does at the rev**
  /// `rust/Cargo.toml` **pins**, and change when that does: the copy and
  /// the behaviour have drifted apart before, leaving a switch drawn that
  /// did nothing.
  static const String description =
      'Keeps sharing what you have watched and downloaded when nothing is '
      'playing. Off, Xtremio shares only while you watch and while a '
      'download is on its way. The light in the corner shows when it is '
      'happening.';

  /// What the settings tile adds on a device where [IdleSharingPolicy]
  /// holds the sharing off while the app is in the background, so nobody
  /// there reads [description] as a promise that it goes on once they
  /// leave. Drawn only there: on a television or a desktop the sharing does
  /// go on, and the sentence would be about some other device.
  static const String backgroundNote =
      'In the background, Xtremio shares only while it is downloading or '
      'casting.';

  /// The gentler of the two stops the status light offers, and what it
  /// costs: nothing is written down, so the next start of the app shares
  /// again. It is the run that ends it and not a session, because a run is
  /// a thing this app has -- [IdleSharingPolicy] lives exactly as long as
  /// the process, and the server it is telling goes down with it -- where a
  /// "session" would be a timer somebody had to choose the length of.
  static const String pauseTitle = 'Not now';
  static const String pauseDescription =
      'Stops sharing what you have watched and downloaded, until you next '
      'start Xtremio. A download on its way still shares. The setting stays '
      'on.';

  /// The other stop: the switch below, from the other end of the app.
  static const String stopTitle = 'Stop sharing';
  static const String stopDescription =
      'Turns this setting off for good, the same switch as in Settings.';

  /// What the popup offers instead of those two when the light is lit with
  /// the setting already off, which it can honestly be for a few seconds:
  /// the light is drawn from bytes the server measured moving and never
  /// from the setting, the server stops uploading at its first pass after
  /// playback ends -- they run every two seconds -- and the light's sample
  /// can still hold the bytes from before that. Neither stop has anything
  /// to do then. One would pause a setting that is already off, and the
  /// other would turn off a switch that is already off, so the popup says
  /// so and offers only the way out of itself.
  static const String alreadyOffTitle = 'Sharing is already off';
  static const String alreadyOffDescription =
      'Xtremio shares only while you watch and while a download is on its '
      'way, and stops a few seconds after both end. There is nothing left '
      'here to switch off.';

  /// What the popup says while a "Not now" is in force and the light is
  /// still lit, which it can be for the same few seconds as above: the
  /// pause tells the server to stop, and the server stops at its next pass.
  /// The "Not now" row would then be a row drawn and dead, since
  /// [IdleSharingPolicy.pauseUntilRestart] takes no second pause, so the
  /// popup says the pause is in force and offers the one stop that still
  /// does something: the switch, which is the longer of the two.
  static const String pausedTitle = 'Paused until you next start Xtremio';
  static const String pausedDescription =
      'What is still going out stops within a few seconds, unless a download '
      'is on its way. The setting is still on.';

  /// What the settings tile adds while a "Not now" is in force. Without it
  /// the tile would show the switch on while nothing is being shared, which
  /// is the exact fault -- a tile describing something the app is not
  /// doing -- that the rest of this class was rewritten to remove.
  ///
  /// It is only ever drawn under a switch that is *on*, and that is what
  /// makes it true. [IdleSharingPolicy] holds that from both ends: a pause
  /// ends when the switch is turned off, and one cannot begin while the
  /// switch is off. So the resumption this promises is the one the setting
  /// will still be asking for at the next start.
  static const String pausedNote = 'Paused until you next start Xtremio.';
}

/// The one call that holds the embedded server's idle sharing off while
/// the app is away, behind an interface so a test can record what the app
/// said.
abstract interface class IdleSharingHold {
  /// Holds the idle sharing off (`true`) or gives it back to the setting
  /// (`false`). Answers whether a server was running to be told; throws
  /// when the call itself failed.
  Future<bool> setHeld(bool held);
}

/// [IdleSharingHold] over FFI (`server_set_idle_sharing_held`), which
/// reaches stream-server's `ServerHandle::set_idle_sharing_held`: not a
/// setting and never persisted, so the app's lifecycle is the whole of
/// its memory.
class RustIdleSharingHold implements IdleSharingHold {
  const RustIdleSharingHold();

  @override
  Future<bool> setHeld(bool held) => rust.serverSetIdleSharingHeld(held: held);
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
/// survive the switch moving, or begin without it: a pause is what a
/// switch that is on looks like this run, either press of the switch is a
/// newer answer than the one the popup took, and with the switch off there
/// is no sharing for a pause to hold back and [pauseUntilRestart] takes
/// none.
///
/// **On a phone or a tablet, the app being in the background is a hold of
/// its own** ([pausesInBackground], from [DeviceProfile.isHandheld]):
/// [appHidden] tells the server to hold the idle sharing off
/// ([IdleSharingHold]) and [appResumed] lets go. It is not written into
/// `seedingEnabled`, which the server persists: the setting keeps saying
/// what the viewer chose, and the hold is a fact about this run that the
/// server forgets with the process. It is the server's to apply because
/// only the server knows what else is happening -- held, a player reading
/// and a torrent download still on its way go on sharing, and what is
/// held off is what was watched or finished before. It is not a "Not now"
/// either: the tile says nothing about it (nobody is looking at the tile
/// while the app is away) and it lifts by itself on the way back, where a
/// "Not now" outlasts every resume of the run it was granted in. The two
/// are held apart so that either can end without ending the other.
/// `XtremioApp` calls both from the lifecycle listener that tells the
/// server's footprint the same thing.
///
/// **It notifies when that pause goes on or off**, and that is the only
/// thing it says anything about: what the server was told is the server's
/// business, but the pause is a state the settings tile draws, and the
/// popup that grants one is drawn over the very screen that tile is on. A
/// preference notifies its own listeners already, so nothing here repeats
/// the switch.
class IdleSharingPolicy extends ChangeNotifier {
  IdleSharingPolicy({
    required this.prefs,
    required this.server,
    required this.hold,
    this.pausesInBackground = false,
  }) : _wasAllowed = prefs.shareWhileIdle;

  /// The viewer's choice, and what tells this when it changes.
  final AppPrefs prefs;

  /// Where the answer goes: one key of the embedded server's settings.
  final ServerSettingsWriter server;

  /// Where the background hold goes ([pausesInBackground]).
  final IdleSharingHold hold;

  /// Whether the app being in the background holds the idle sharing off:
  /// true on a phone or a tablet ([DeviceProfile.isHandheld]), false on a
  /// television and a desktop, which go on sharing behind other windows.
  /// Fixed for the run, because the device is. Also what the settings tile
  /// reads to say so.
  final bool pausesInBackground;

  /// The app is in the background, as [appHidden] and [appResumed] last
  /// said. Only counts where [pausesInBackground] does.
  bool _background = false;

  /// [start] has run, so the preferences are in and the server may be
  /// told: a lifecycle change before then is recorded and not pushed, or
  /// the server would hear an answer ahead of the viewer's own.
  bool _watching = false;

  /// What the server was last told, or null when it has been told nothing
  /// (or when the telling failed, so the next change tries again).
  bool? _sent;

  /// What the server was last told of the hold, or null when the telling
  /// failed. A server starts unheld, so there is nothing to say until the
  /// app goes away.
  bool? _heldSent = false;

  /// The hold's calls, chained like [_writes] and for the same reason.
  Future<void> _holds = Future<void>.value();

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
    _watching = true;
    prefs.addListener(_reconsider);
    _reconsider();
    _reconsiderHold();
  }

  /// The app went into the background (hidden, or paused after it). On a
  /// phone or a tablet the idle sharing is held off until [appResumed];
  /// anywhere else this changes nothing.
  void appHidden() {
    if (_background) return;
    _background = true;
    if (_watching) _reconsiderHold();
  }

  /// The app is in the foreground again, and the setting (and any "Not
  /// now") says what is shared, as it did before [appHidden].
  void appResumed() {
    if (!_background) return;
    _background = false;
    if (_watching) _reconsiderHold();
  }

  /// Everything written so far has landed. For tests; nothing in the app
  /// waits on this policy.
  @visibleForTesting
  Future<void> get settled => Future.wait([_writes, _holds]);

  /// Stops the sharing for the rest of this run, leaving the preference
  /// alone: what the status light's "Not now" does.
  ///
  /// The server is told at once, through the one path that tells it
  /// anything. Nothing persists it, so the next start of the app pushes the
  /// preference again and sharing resumes -- which is what the popup says
  /// it does, and the whole difference between this and the switch.
  ///
  /// **With the switch off it does nothing, and that is the invariant
  /// rather than a guard.** A pause is a state of a switch that is on: it
  /// holds back a sharing the setting still allows. With the setting off
  /// there is no such sharing to hold back, and a pause recorded anyway
  /// would have the settings tile promise a resumption at the next start
  /// that the setting will not be asking for. The popup does not draw the
  /// row while the switch is off, so nothing presses this then; it is
  /// refused here as well because whether a pause can exist is this
  /// object's to answer and not the order its callers press things in.
  void pauseUntilRestart() {
    if (_paused || _stopped || !prefs.shareWhileIdle) return;
    _paused = true;
    _reconsider();
    notifyListeners();
  }

  /// A "Not now" is in force, which it can only be while the setting is
  /// on: [pauseUntilRestart] refuses one while the switch is off, and
  /// [_reconsider] lifts one the moment the switch moves either way. What
  /// reads it is the settings tile, which must not show a switch
  /// that is on over a run in which nothing is being shared -- and which
  /// is on screen when the popup that grants one is, so this notifies when
  /// it changes.
  bool get pausedForRun => _paused;

  void _reconsider() {
    if (_stopped) return;
    // A pause is a state of a switch that is *on*, and it ends the moment
    // the switch moves. Since [pauseUntilRestart] refuses one while the
    // switch is off, the one move a held pause can see is the switch going
    // off, and that lifts it: the switch is the longer of the two stops,
    // and "paused until you next start Xtremio" under a switch that is off
    // would promise a resumption that is never coming. The comparison is
    // written as "moved" rather than "turned off" as a guard: should a
    // pause ever be held under a switch that is off, turning it on must
    // not leave the viewer with a switch they have just pressed that does
    // nothing until the app is restarted.
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

  void _reconsiderHold() {
    if (_stopped) return;
    final held = pausesInBackground && _background;
    if (held == _heldSent) return;
    _heldSent = held;
    _holds = _holds.then((_) => _pushHold(held));
  }

  Future<void> _pushHold(bool held) async {
    try {
      // "No server to tell" is not remembered as told: a server that comes
      // up later starts unheld, and the next trip out tells it.
      if (!await hold.setHeld(held) && _heldSent == held) _heldSent = null;
    } catch (error) {
      if (kDebugMode) debugPrint('idle sharing hold not applied: $error');
      if (_heldSent == held) _heldSent = null;
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
