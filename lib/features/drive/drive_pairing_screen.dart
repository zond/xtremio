import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/external_link.dart';
import '../player/player_screen.dart';

/// Linking files in somebody's Google Drive to this device, which is a
/// pairing made on a second screen.
///
/// The television cannot run the Google Picker -- it is web-only -- and
/// cannot hold an OAuth client secret, because it is an app anybody can
/// unpack. So a phone does the signing in and the picking, the service in
/// `drive-link/` does the two things that need the secret, and this screen
/// is the television's whole part: ask for a session, draw it, poll until
/// the phone has finished, hand what comes back to [DriveAccount].
///
/// **Two shapes, one flow.** On a television the session is drawn -- the QR
/// for the link, and nothing else, because nothing on that screen can be
/// typed into and the second device is the point. On a phone or a desktop
/// there is no second device, and scanning your own screen is absurd, so the
/// app opens the link itself and waits for the same answer. That is the split
/// this app makes everywhere ([DeviceScope.isTv]). Two shapes here, but
/// *three* on the wire: what the page has to say at the end splits the phone
/// from the desktop, which this screen treats alike -- see the hand-back
/// below.
///
/// **One pairing links everything the viewer picked.** The Picker takes
/// several files at once, so a scan can link a whole season, and
/// [DrivePairingCollected.files] is a list for that reason. One file is not a
/// special case of it anywhere but in what the screen *says*, which has to
/// read properly for one as well as twenty ([linkedHeadline]).
///
/// **The browser is the system's, never a web view.** Google refuses OAuth
/// in an embedded user agent (`disallowed_useragent`), so
/// `LaunchMode.inAppWebView` would not fail at the end of the flow but at
/// the start of it, on the sign-in page. The link goes out through
/// [openInBrowser], which is [UrlLauncherLinkOpener] and hard-codes
/// `LaunchMode.externalApplication`.
///
/// **The hand-back is a link nothing acts on.** A viewer on a phone was
/// handed to a browser by this app, and leaving them there with a page that
/// says "on its way" and nothing to press is the one part of the phone shape
/// that was plainly wrong. So the pick page now navigates to
/// [drivePairingHandBackLink] when it is finished -- but only for a session
/// that asked ([DrivePairingShape.handsBack]), and this app does not act on
/// the link when it arrives.
///
/// That is what answers what was written here against `app_links`, rather
/// than ignoring it. The objection was never the dependency, which is
/// already in the app: it was that `stremio://` means exactly one thing
/// (open that addon's details, install nothing -- `AGENTS.md`), that a
/// second meaning on a channel the platform hands to anybody is a second
/// thing to get wrong, and that `app_links` replays the launch link on a
/// cold start, so a hand-back kept by the platform could reopen this screen
/// days later for a session that no longer exists. A host-less
/// `stremio:///pair` is already the shape `deepLinkAddonManifestUrl` drops,
/// so **no second meaning is added and nothing new is dispatched**: the link
/// arrives, is recognised as nothing, and is dropped -- on a cold start
/// exactly as when the app is up. What brings the app forward is the
/// platform switching tasks, which is the whole of what a hand-back is. The
/// third objection, that this saves only one Back press, was true and is
/// what the owner asked for anyway; polling is unchanged and still what
/// collects the pairing.
///
/// A television asks for no hand-back, and neither does a desktop: the
/// scheme's registration there is installed by hand or not at all
/// (`docs/DEEP_LINKS.md`), and a browser sent to a scheme nothing handles
/// shows an error page where a confirmation should be. So the hand-back is
/// the phone and the tablet alone, where the registration ships with the
/// app.
///
/// **The service is told which of three shapes asked, not whether to hand
/// back** ([_shapeOf], [DrivePairingShape]). Those are not the same fact,
/// and taking them as one is what made the pick page tell a desktop its
/// files were on the way to "your television": the two shapes that want no
/// hand-back want it for opposite reasons, and the page has something
/// different to say to each. A television's viewer is already looking
/// elsewhere; a desktop's is looking at the page, and is told the pairing
/// landed in the app and the window can be closed.
///
/// **Polling ends.** A session lasts about ten minutes and the screen says
/// so; when it is up, the screen says *that* and offers a fresh code rather
/// than spinning. Three things can end it -- the pairing arriving, the
/// window closing, and the session turning out not to be there -- and each
/// has somewhere to go on the screen. Nothing retries past a terminal
/// answer; a failed poll is not one (see [DrivePairingUnreachable]).
///
/// **The collecting read is one-shot**, and three things hold it to that.
/// The poll timer is *not* periodic: the next one is armed when the last
/// answer is in, so two reads are never in flight and a slow answer cannot
/// be overtaken by the read that turns it into a `404`. A
/// [DrivePairingCollected] cancels both timers before it does anything else.
/// And [_collected] latches, so the token reaches [DriveAccount] once even
/// if something contrives to deliver it twice. The same answer is handed
/// over **whether or not this screen is still mounted**: the session is
/// deleted on the service the instant it is read, so that object is the only
/// copy of the credential, and dropping it because the viewer pressed Back
/// half a second early would lose a pairing they completed.
///
/// **The token is never drawn, never logged, never in an error.** It goes
/// from the response object into [DriveAccount.linkFiles] in one statement
/// and is in no field of this state. What the screen draws about a finished
/// pairing is the files' names. And [DriveLinkOutcome.thisRunOnly] -- the
/// secure store refusing the write -- is said out loud rather than dressed
/// up as success: the pairing works now and will be gone after a restart,
/// which is a thing a viewer would want to know before they settle in.
class DrivePairingScreen extends StatefulWidget {
  const DrivePairingScreen({
    super.key,
    this.service = const XtremioDrivePairingService(),
    this.opener = const ServerDriveFileOpener(),
    this.picker = const MethodChannelDriveNativePicker(),
    this.pollEvery = defaultPollEvery,
    this.now = DateTime.now,
  });

  /// Where the sessions come from; a widget test hands in a fake rather
  /// than reaching the deployed service.
  final DrivePairingService service;

  /// What picks Drive files without a browser, when this device can. See
  /// [_pickHere] for when that is and why it matters.
  final DriveNativePicker picker;

  /// What turns a linked file into a URL the player can open. Injected for
  /// the same reason [service] is: a widget test plays a file without
  /// reaching FFI, and it can say which id and which token went down.
  final DriveFileOpener opener;

  /// How often the television asks whether the phone has finished.
  final Duration pollEvery;

  /// The clock the session's window is measured from, so a test can pin the
  /// moment ([DriveAccount] takes one for the same reason).
  final DateTime Function() now;

  /// Three seconds, and the number is about two things.
  ///
  /// What it has to be fast enough for is only the *last* hop: the seconds
  /// between a viewer tapping a file in the Picker and the television
  /// reacting. Everything before that -- finding the phone, the camera, a
  /// Google password, two-factor, scrolling a Drive -- takes between half a
  /// minute and several, and no polling interval makes any of it quicker.
  /// Three seconds means an average wait of a second and a half after the
  /// tap, which reads as "it noticed"; one second would cost three times the
  /// requests to buy one second of feeling.
  ///
  /// What it has to be slow enough for is cost. `GET /session/{id}` carries
  /// no rate limit of its own in the service today -- only `POST /session`
  /// (sixty an hour per address) and `POST /refresh` do -- so what bounds
  /// this is not a `429` but a Firestore read and a function invocation per
  /// poll, on a project with no budget cap
  /// (`drive-link/README.md`, "What is deliberately not here"). Three
  /// seconds over the whole ten minutes is two hundred reads for one
  /// pairing, which is nothing, and it is bounded because the window is:
  /// the screen stops asking rather than sitting on a code all evening.
  ///
  /// It is also why a fresh code is a press and not automatic. Reopening a
  /// session is the call that *is* limited, and a screen that renewed
  /// itself would spend that limit while nobody was in the room.
  static const Duration defaultPollEvery = Duration(seconds: 3);

  /// How long the service gives a session (`SESSION_MINUTES`), and the most
  /// this screen will wait.
  static const Duration sessionWindow = Duration(minutes: 10);

  /// And the least. See [windowOf].
  static const Duration shortestWindow = Duration(seconds: 30);

  /// What the screen says while it is waiting, and what it says when the
  /// waiting is over. Constants because the tests name them, and a message
  /// a test quotes by hand is one that can be changed without the test
  /// noticing.
  static const String title = 'Link files';

  /// The service would not take what this device picked. Both causes read
  /// the same to a viewer: Google refused the one-time code, or the grant it
  /// minted could not open the files that were picked.
  static const String handoverRefused =
      'That could not be confirmed with Google. Try again.';
  static const String scanHeading = 'Scan this with your phone';
  static const String browserHeading = 'Finish this in your browser';
  static const String openingMessage = 'Asking for a code…';

  /// What a device picking *here* says, which is neither of the above: no
  /// code is being scanned and no browser is being finished in. The picker
  /// is a window on top of this screen, so what is behind it is a sentence
  /// about what happens when it closes.
  static const String pickingHeading = 'Choose what to play';
  static const String pickingMessage = 'Google Drive is open…';
  static const String addingMessage = 'Adding what you chose…';
  static const String waitingMessage = 'Waiting for your phone…';

  /// Said out loud, because nothing in the Picker suggests it: a viewer who
  /// does not know several can be chosen picks one and presses the button.
  static const String signedInMessage =
      'Signed in. Now pick what to play — '
      'you can pick more than one file.';
  static const String inBrowserMessage =
      'Sign in to Google in the page that '
      'opened and pick what you want to play — you can pick more than one '
      'file. This screen is watching for it.';
  static const String windowMessage = 'This lasts about ten minutes.';

  /// What a device that picks in place says when the picker closed with
  /// nothing chosen. Not "waiting for your phone": no phone is involved and
  /// nothing is being waited for -- the viewer backed out, which is a thing
  /// they are allowed to do, so this says what to press to go back in.
  static const String nothingChosenMessage =
      'Nothing chosen yet. Open Google Drive to pick what to play.';
  static const String chooseFilesLabel = 'Choose files';

  /// The service could not be reached while finishing. Unlike the others
  /// this is worth retrying rather than re-pairing: the pairing is still
  /// sitting on the service, its id is written down, and the next library
  /// will ask for it again.
  static const String unreachableMessage =
      'Could not reach the service just now. This will finish by itself '
      'when it can.';
  static const String expiredMessage =
      'That code has expired before anybody '
      'finished with it.';
  static const String lostMessage =
      'That pairing did not finish. Nothing has '
      'been linked.';
  static const String thisRunOnlyMessage =
      'This device has no secure store '
      'that would take the pairing, so it lasts until the app closes. '
      'Everything works now; you will have to link the file again after a '
      'restart.';
  static const String freshCodeLabel = 'New code';
  static const String openAgainLabel = 'Open the page again';
  static const String doneLabel = 'Done';
  static const String playLabel = 'Play';
  static const String openingFileMessage = 'Opening that file…';

  /// What the screen says about a pairing that has just arrived.
  ///
  /// One file names itself, because that is what the viewer would look for
  /// and it is still the commonest pairing by far. Several are counted:
  /// twelve filenames stacked on a television is a wall of text read from an
  /// armchair, and the rows underneath name them anyway. A file the Picker
  /// sent no name for falls back to the wording a nameless single file has
  /// always had.
  static String linkedHeadline(List<String> names) {
    if (names.length > 1) return '${names.length} files are linked.';
    final name = names.isEmpty ? '' : names.single;
    return name.isEmpty ? 'That file is linked.' : '"$name" is linked.';
  }

  /// How long this screen waits before it calls a session dead, counted
  /// from the moment the session opened.
  ///
  /// A length and not a deadline, and clamped, because the two ends of that
  /// subtraction are not on the same clock: [DrivePairingSession.expiresAt]
  /// is the service's time and [now] is a television's, which is set by
  /// whatever DHCP handed it and is routinely wrong by hours. A set running
  /// behind would read the window as hours and never stop polling; one
  /// running ahead would read it as already over and refuse to draw a code
  /// that works perfectly well. So the difference is taken as a hint and
  /// held between [shortestWindow] and [sessionWindow], and the service's
  /// own `410` is what really ends a session either way -- which is why a
  /// clamp is safe here and a comparison would not have been.
  static Duration windowOf(DrivePairingSession session, DateTime now) {
    final left = session.expiresAt.difference(now.toUtc());
    if (left > sessionWindow) return sessionWindow;
    if (left < shortestWindow) return shortestWindow;
    return left;
  }

  @override
  State<DrivePairingScreen> createState() => _DrivePairingScreenState();
}

/// Where the screen is, which is also which of the three outcomes it landed
/// on once it stops moving.
/// Whether this device is doing its own picking, and how far it has got.
///
/// Drawn instead of the scan/browser wording, which is about somebody
/// else's screen and is a lie here. It is a *phase of waiting* rather than
/// a [_Stage]: the session is open and being polled throughout, and every
/// way the wait can end -- the window closing, the service refusing -- still
/// ends it.
enum _Picking { no, choosing, adding }

enum _Stage {
  /// Asking the service for a session.
  opening,

  /// A session is drawn (or open in a browser) and being polled.
  waiting,

  /// The pairing arrived and [DriveAccount] has it.
  linked,

  /// The window closed with nobody having finished.
  expired,

  /// The session could not be opened, or turned out not to be there. The
  /// third outcome, and the one that carries a sentence of its own.
  refused,
}

class _DrivePairingScreenState extends State<DrivePairingScreen> {
  _Stage _stage = _Stage.opening;
  DrivePairingSession? _session;
  bool _signedIn = false;

  /// Why, in the [_Stage.refused] case. Written by the service layer or
  /// here, never echoed from a response body.
  String _refusal = '';

  /// What the pairing linked, for the screen to name and to offer -- and
  /// nothing else about the pairing is kept, least of all the credential.
  ///
  /// The ids and the names, not the rows: the account is the record of what
  /// is linked, so [_Stage.linked] looks each id up there rather than
  /// drawing a second copy that could disagree with it.
  List<DrivePairingFile> _linked = const [];
  bool _thisRunOnly = false;

  /// A file is being opened. It is one round trip to the pairing service
  /// and one to Google, so it is worth saying out loud, and it is what
  /// stops a second press starting a second open.
  bool _playing = false;

  Timer? _poll;
  Timer? _window;

  /// The credential has been handed over. Latches: the service deleted the
  /// session when it answered, so a second hand-over is a second write of
  /// the same token at best and a lost one at worst.
  bool _collected = false;

  /// See [_Picking]. Only ever anything but `no` on a device that picks
  /// without a browser.
  _Picking _picking = _Picking.no;

  /// This device did the picking itself, so the pairing ends by going back
  /// rather than by saying it happened. Latched, because by the time the
  /// answer arrives [_picking] is over.
  bool _pickedHere = false;

  /// A browser really was opened, so the block that talks about "the page
  /// that opened" has a page to be about.
  ///
  /// It used to be drawn for every device that is not a television, which
  /// was true while a phone always went out through a browser. A phone that
  /// picks in place opens no page, and the block told the viewer to sign in
  /// to one that was not there -- and offered a button to open it, which is
  /// the one thing on that screen they should not press.
  bool _openedBrowser = false;

  /// This screen is listening to the account's pairing job.
  bool _watchingJob = false;

  /// Guards against two `POST /session` calls overlapping -- a press on
  /// "New code" while the first is still out.
  bool _opening = false;

  /// Taken from the scope once, because the completion of a poll may arrive
  /// after this screen is gone and must still be able to store what it was
  /// handed. Reading it off [context] then would be reading a dead tree.
  DriveAccount? _account;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final account = _account ??= DriveAccountScope.of(context);
    // Watched, not owned. The job belongs to the account and runs whether or
    // not this screen is here; what this listener is for is the one thing
    // the screen still does -- getting out of the way when it is done.
    if (!_watchingJob) {
      _watchingJob = true;
      account.pairing.addListener(_onPairingJob);
    }
    if (_stage != _Stage.opening || _session != null || _opening) return;
    // A code every time, on a device that has never paired and on one that
    // linked a season last week alike.
    //
    // **This spends the rate-limited call on purpose**, which is a reversal
    // of what used to be written here. This screen used to open on the list
    // of everything already linked, and the argument for it was that a
    // viewer coming back mostly wanted to play something, so asking for a
    // session nobody wanted spent `POST /session` -- sixty an hour per
    // address, the one call the service limits -- for nothing. That
    // argument has expired: a linked file now has two homes of its own, the
    // library's **Remote** pill and its own details page as a source, so
    // nobody arrives here to play. What is left is the one thing the cloud
    // button means, which is *add something*, and a code is the whole of
    // that. Spending the call is then exactly what the viewer asked for,
    // and the bound on it is unchanged: a fresh code is still a press and
    // never automatic (see [DrivePairingScreen.defaultPollEvery]), so
    // nothing here renews itself while nobody is in the room.
    //
    // The first session is asked for once the scope is in reach, not in
    // `initState`, because [_open] reads [DeviceScope].
    unawaited(_open());
  }

  @override
  void dispose() {
    if (_watchingJob) _account?.pairing.removeListener(_onPairingJob);
    // Leaving the screen stops the asking. The answer to a poll already out
    // is still handed over (see the class comment); what stops is arming
    // another one.
    _poll?.cancel();
    _window?.cancel();
    super.dispose();
  }

  /// Whether a finished pairing should put this app back in front of the
  /// viewer, which is asked of the service when the session is opened.
  ///
  /// Which of the three shapes this device is, in the service's terms.
  ///
  /// The television first, because `hasTouch` is true on some of them and
  /// the remote is what decides that split everywhere else in this app.
  /// After that, touch tells a phone or tablet from a desktop -- which is
  /// the line the hand-back falls on, and the line the pick page's own
  /// wording falls on. See [DrivePairingShape] and the class comment.
  static DrivePairingShape _shapeOf(DeviceProfile device) => device.isTv
      ? DrivePairingShape.television
      : device.hasTouch
      ? DrivePairingShape.phone
      : DrivePairingShape.desktop;

  /// Asks for a session and starts the waiting, or says why it could not.
  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    _poll?.cancel();
    _window?.cancel();
    // Read before the await and not after it: which shape this is decides
    // what the service is asked for, and `context` is not something to reach
    // into once a network call has been waited on.
    final device = DeviceScope.of(context);
    if (mounted) {
      setState(() {
        _stage = _Stage.opening;
        _session = null;
        _signedIn = false;
        _refusal = '';
      });
    }
    final opening = await widget.service.open(shape: _shapeOf(device));
    _opening = false;
    if (!mounted) return;
    switch (opening) {
      case DrivePairingUnavailable(:final reason):
        setState(() {
          _stage = _Stage.refused;
          _refusal = reason;
        });
      case DrivePairingOpened(:final session):
        setState(() {
          _stage = _Stage.waiting;
          _session = session;
        });
        _window = Timer(
          DrivePairingScreen.windowOf(session, widget.now()),
          _closeWindow,
        );
        _armPoll();
        // A phone has no second screen to scan with, so this device does the
        // picking itself -- natively where it can, and in a browser where it
        // cannot. Once, here, rather than on every rebuild.
        if (!device.isTv && !await _pickHere(session)) {
          if (!mounted) return;
          setState(() => _openedBrowser = true);
          await openInBrowser(context, session.link);
        }
    }
  }

  /// The account's job finished. All this screen does about it is stop
  /// being in the way.
  ///
  /// It never *stores* anything: the job did that, on the account, before
  /// this ran. A screen that had gone away by now missed only this step,
  /// which is the point.
  void _onPairingJob() {
    final job = _account?.pairing;
    if (!mounted || job == null || job.running) return;
    final outcome = job.outcome;
    if (outcome == null) return;
    switch (outcome) {
      case DrivePairingJobOutcome.linked:
        unawaited(_leave());
      case DrivePairingJobOutcome.thisRunOnly:
        // Said out loud rather than slipped past: the pairing works now and
        // is gone after a restart, which a viewer wants to know before they
        // settle in.
        setState(() {
          _picking = _Picking.no;
          _stage = _Stage.linked;
          _thisRunOnly = true;
        });
      case DrivePairingJobOutcome.gone:
        _refuse(DrivePairingScreen.lostMessage);
      case DrivePairingJobOutcome.refused:
        _refuse(DrivePairingScreen.handoverRefused);
      case DrivePairingJobOutcome.unreachable:
        _refuse(DrivePairingScreen.unreachableMessage);
    }
  }

  void _refuse(String said) => setState(() {
    _picking = _Picking.no;
    _stage = _Stage.refused;
    _refusal = said;
  });

  /// Goes back where this screen was pushed from, or says it is done when
  /// it cannot. `maybePop` is allowed to refuse, and a screen that trusted
  /// it stayed on a spinner over work that had finished.
  Future<void> _leave() async {
    if (await Navigator.of(context).maybePop()) return;
    if (!mounted) return;
    setState(() {
      _picking = _Picking.no;
      _stage = _Stage.linked;
    });
  }

  /// Opens the picker again on a session that is still good.
  ///
  /// Not a fresh session: the one this screen holds is still open, still
  /// polled and still inside its ten minutes, and asking for another would
  /// spend a call the service rate-limits to buy nothing.
  Future<void> _pickAgain() async {
    final session = _session;
    if (session == null || _picking != _Picking.no) return;
    await _pickHere(session);
  }

  /// Picks on *this* device, and whether that happened.
  ///
  /// **The bug this exists to kill.** A phone used to open its own pairing
  /// link in a browser. With the link now an App Link, Android handed it
  /// straight back to this app, which picked natively, posted to the session
  /// -- and left *this* screen to poll the result back. That works only
  /// while this screen is alive, and by then the viewer has pressed Done on
  /// the screen in front of it and gone back to their library. The session
  /// sat at `ready` until it expired, three times in a row, with every other
  /// part of the flow working perfectly.
  ///
  /// So a phone pairing with itself never leaves this screen: the picker is
  /// an activity on top of it, not a place to navigate to, so the poll that
  /// collects is still running when the answer lands. The App Link path is
  /// then only what it was ever for -- a phone scanning a *television's* QR,
  /// where the files really are going somewhere else.
  ///
  /// False means "not done here": no native picker on this device, or one
  /// that turned out not to be there after all, and the browser is the
  /// answer. Every other outcome is true, because the viewer has already
  /// been shown a picker and sending them to a second one would be the app
  /// arguing with itself.
  Future<bool> _pickHere(DrivePairingSession session) async {
    // Everything the pick needs is taken *before* the first await, and
    // nothing after it reads `widget` or `_account`. A viewer can leave
    // while the picker is up -- that is the ordinary case this whole
    // arrangement is for -- and a method that went looking for its own
    // widget afterwards would drop the pairing on the floor exactly where
    // the old one did, one level further in.
    final picker = widget.picker;
    final account = _account;
    if (account == null) return false;
    if (!await picker.available()) return false;
    _say(() {
      _picking = _Picking.choosing;
      _pickedHere = true;
    });
    final picked = await picker.pick();
    _say(() => _picking = _Picking.no);
    switch (picked) {
      case DriveNativePickUnavailable():
        return false;
      case DriveNativePickCancelled():
        // Nothing was chosen. The code is still good and the screen is still
        // waiting, so this is not a refusal -- it is a viewer who changed
        // their mind, and the window is what ends it.
        return true;
      case DriveNativePickFailed(:final reason):
        _say(() {
          _stage = _Stage.refused;
          _refusal = reason;
        });
        return true;
      case DriveNativePicked(:final serverAuthCode, :final fileIds):
        _say(() => _picking = _Picking.adding);
        // Handed to the account, which outlives this screen, and **not
        // awaited here**. This screen's own polling stops first, so the
        // collecting read -- destructive, and answering exactly once --
        // happens in one place.
        _poll?.cancel();
        _window?.cancel();
        unawaited(
          account.pairing.finish(
            sessionId: session.sessionId,
            serverAuthCode: serverAuthCode,
            fileIds: fileIds,
          ),
        );
        return true;
    }
  }

  /// `setState`, or nothing at all when this screen has gone.
  ///
  /// The distinction the old code got wrong: a viewer who has walked away
  /// should stop the *drawing*, not the work.
  void _say(VoidCallback change) {
    if (!mounted) return;
    setState(change);
  }

  /// The window closed. Said plainly, with a way on.
  void _closeWindow() {
    _poll?.cancel();
    if (!mounted || _stage != _Stage.waiting) return;
    setState(() => _stage = _Stage.expired);
  }

  /// One poll, at a time, and the next one armed when this one is done.
  ///
  /// Never `Timer.periodic`. A periodic timer firing while a slow answer is
  /// still coming back is the second read the session cannot survive: the
  /// first read hands over the tokens and deletes the session, the second
  /// gets a `404`, and whichever of them the screen happens to look at last
  /// is what the viewer sees.
  void _armPoll() {
    _poll?.cancel();
    _poll = Timer(widget.pollEvery, _pollOnce);
  }

  Future<void> _pollOnce() async {
    final session = _session;
    if (session == null || _collected) return;
    final answer = await widget.service.collect(session.sessionId);

    // A collected pairing is never dropped, whatever else has happened
    // since -- not for this screen being gone, not for the window having
    // closed, not for the viewer having asked for a fresh code a moment
    // before. The session is deleted on the service now, so this object is
    // the credential; refusing it because the screen moved on would throw
    // away a pairing the viewer really did complete.
    if (answer case final DrivePairingCollected collected) {
      await _store(collected);
      return;
    }

    // Everything else is about the session being waited for, so an answer
    // for one this screen has moved past says nothing.
    if (!mounted ||
        _stage != _Stage.waiting ||
        _session?.sessionId != session.sessionId) {
      return;
    }
    switch (answer) {
      case DrivePairingWaiting(:final signedIn):
        if (signedIn != _signedIn) setState(() => _signedIn = signedIn);
        _armPoll();
      case DrivePairingUnreachable():
        // Not a verdict. A television drops off its wifi and comes back,
        // and the window is the bound on trying again rather than a count.
        _armPoll();
      case DrivePairingExpired():
        _poll?.cancel();
        _window?.cancel();
        setState(() => _stage = _Stage.expired);
      case DrivePairingGone():
        _poll?.cancel();
        _window?.cancel();
        setState(() {
          _stage = _Stage.refused;
          _refusal = DrivePairingScreen.lostMessage;
        });
      case DrivePairingCollected():
        // Handled above, before anything could decide to drop it.
        break;
    }
  }

  /// Hands the credential to [DriveAccount], once, and says what the store
  /// managed to do with it.
  Future<void> _store(DrivePairingCollected collected) async {
    if (_collected) return;
    _collected = true;
    _poll?.cancel();
    _window?.cancel();
    final account = _account;
    if (account == null) return;
    // One statement, from the response into the account -- every file the
    // pairing named, in one write. The token is in no field of this state
    // and in no line of the log.
    final outcome = await account.linkFiles(
      refreshToken: collected.refreshToken,
      files: collected.files,
    );
    if (!mounted) return;
    // A device that did its own picking goes straight back to where the
    // viewer pressed the button, because it is already there: they chose
    // their files a second ago and the screen behind this one is the
    // library those files are now in. A confirmation would be a page whose
    // only content is "yes, the thing you just did happened", with a Done
    // to press before they can look.
    //
    // Not when the store refused to keep the credential ([thisRunOnly]):
    // that is news, it is about *later*, and it is the one thing this
    // screen has to say that the library cannot.
    if (_pickedHere && outcome != DriveLinkOutcome.thisRunOnly) {
      // Asked, not assumed. `maybePop` is allowed to refuse -- a route that
      // is the first of its navigator, or anything that has taken the back
      // button -- and a screen that trusted it silently stayed exactly where
      // it was, on a spinner, after a pairing that had already finished.
      // That is what this looked like on a real phone: the files were in the
      // library and the screen was still saying "adding".
      if (await Navigator.of(context).maybePop()) return;
      if (!mounted) return;
    }
    setState(() {
      _stage = _Stage.linked;
      _linked = collected.files;
      _thisRunOnly = outcome == DriveLinkOutcome.thisRunOnly;
    });
  }

  /// One file, as a row that plays it.
  Widget _fileRow(LinkedDriveFile file) => ListTile(
    key: Key('drive-file-${file.fileId}'),
    // The floor and nothing put on by hand: a [ListTile] on the
    // scaffold's own surface is Material's ink, so [FocusTheme] marks
    // it with the fill, and there is no poster art under it for a wash
    // to disappear into (`AGENTS.md`, "Prefer the floor").
    leading: const Icon(Icons.movie_outlined),
    title: Text(file.name.isEmpty ? file.fileId : file.name),
    subtitle: const Text(driveSourceLabel),
    trailing: const Icon(Icons.play_arrow),
    enabled: !_playing,
    onTap: () => unawaited(_play(file)),
  );

  /// Opens [file] on the embedded server and pushes the player at it.
  ///
  /// The whole of what this knows about the credential is that it does not
  /// have it: [openLinkedDriveFile] asks the account, which is the only
  /// thing that holds one. A dead pairing is written down in there too, so
  /// what is left here is a sentence and a code to scan -- the account's
  /// state is already [DriveLinkState.pairAgain] by the time this draws,
  /// and the rows the confirmation was offering are no longer any use.
  Future<void> _play(LinkedDriveFile file) async {
    final account = _account;
    if (account == null || _playing) return;
    setState(() {
      _playing = true;
      _refusal = '';
    });
    final opened = await openLinkedDriveFile(
      account: account,
      file: file,
      opener: widget.opener,
    );
    if (!mounted) return;
    switch (opened) {
      case DriveFilePlayable():
        setState(() => _playing = false);
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: PlayerScreen.routeName),
            builder: (_) => PlayerScreen(
              stream: driveStreamJson(file: file, playable: opened),
            ),
          ),
        );
      case DriveFileRefused(:final reason):
        setState(() {
          _playing = false;
          _refusal = driveFailureMessage(reason);
          // The grant is gone, so what was just linked is a film this
          // device cannot read: a code is the only thing left to offer.
          if (reason == DriveOpenFailure.pairAgain ||
              reason == DriveOpenFailure.notLinked) {
            _stage = _Stage.refused;
          }
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTv = DeviceScope.isTv(context);
    return Scaffold(
      appBar: AppBar(title: const Text(DrivePairingScreen.title)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                spacing: 16,
                children: _body(context, isTv),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, bool isTv) {
    final theme = Theme.of(context);
    switch (_stage) {
      case _Stage.opening:
        return [_Line(DrivePairingScreen.openingMessage, theme: theme)];
      case _Stage.waiting:
        final session = _session!;
        return [
          Text(
            _picking != _Picking.no
                ? DrivePairingScreen.pickingHeading
                : isTv
                ? DrivePairingScreen.scanHeading
                : _openedBrowser
                ? DrivePairingScreen.browserHeading
                : DrivePairingScreen.pickingHeading,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          if (isTv)
            PairingQrCode(link: session.link)
          else if (_openedBrowser)
            ..._openedSession(session, theme),
          // Drawn while this device is doing the work itself, because that
          // is the only part of the wait that looks like nothing happening.
          // A television waiting for a phone has a QR to look at and a
          // viewer who knows they have not scanned it yet; here the viewer
          // has done their part, the app is talking to Google about every
          // file they chose, and a line of text that does not move reads as
          // stuck. It is: a season of twelve is twelve files to ask about.
          // Backing out of the picker used to leave this screen with no QR,
          // no page, nothing to press and a line saying it was waiting for a
          // phone that was never involved. The session is still open and
          // still good, so the honest offer is the picker again.
          if (!isTv && !_openedBrowser && _picking == _Picking.no)
            FilledButton.icon(
              onPressed: () => unawaited(_pickAgain()),
              icon: const Icon(Icons.folder_open),
              label: const Text(DrivePairingScreen.chooseFilesLabel),
            ),
          if (_picking != _Picking.no) ...[
            const SizedBox(height: 8),
            const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 4),
          ],
          _Line(switch (_picking) {
            _Picking.choosing => DrivePairingScreen.pickingMessage,
            _Picking.adding => DrivePairingScreen.addingMessage,
            _Picking.no =>
              _signedIn
                  ? DrivePairingScreen.signedInMessage
                  : !isTv && !_openedBrowser
                  ? DrivePairingScreen.nothingChosenMessage
                  : DrivePairingScreen.waitingMessage,
          }, theme: theme),
          // Only where there is a code somebody still has to do something
          // with: a QR on a television, or a page opened in a browser. A
          // device picking in place is not racing a clock it can see, and
          // the line reads as one more thing about a code that is not on
          // screen.
          if (isTv || _openedBrowser)
            _Line(DrivePairingScreen.windowMessage, theme: theme, quiet: true),
        ];
      case _Stage.linked:
        // Looked up in the account rather than drawn from what came back:
        // the account is the record of what is linked, and a row it does not
        // have is a row nothing here could play.
        final justLinked = [
          for (final file in _linked) ?_account?.files.forFile(file.fileId),
        ];
        return [
          Icon(
            Icons.check_circle_outline,
            size: 40,
            color: theme.colorScheme.primary,
          ),
          Text(
            DrivePairingScreen.linkedHeadline([
              for (final file in _linked) file.name,
            ]),
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          if (_thisRunOnly)
            _Line(
              DrivePairingScreen.thisRunOnlyMessage,
              theme: theme,
              warning: true,
            ),
          if (_refusal.isNotEmpty) _Line(_refusal, theme: theme, warning: true),
          if (_playing)
            _Line(DrivePairingScreen.openingFileMessage, theme: theme),
          // Straight into the film from the screen that linked it: the
          // pairing is the one moment the viewer is certainly holding a
          // remote and certainly means to watch what they just picked. One
          // file is one press; a season is a row each, because "Play" over
          // twelve episodes would have to guess which one.
          if (justLinked.length == 1)
            FilledButton.icon(
              onPressed: _playing
                  ? null
                  : () => unawaited(_play(justLinked.single)),
              icon: const Icon(Icons.play_arrow),
              label: const Text(DrivePairingScreen.playLabel),
            )
          else
            ...justLinked.map(_fileRow),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text(DrivePairingScreen.doneLabel),
          ),
        ];
      case _Stage.expired:
        return [
          _Line(DrivePairingScreen.expiredMessage, theme: theme),
          FilledButton(
            onPressed: () => unawaited(_open()),
            child: const Text(DrivePairingScreen.freshCodeLabel),
          ),
        ];
      case _Stage.refused:
        return [
          _Line(_refusal, theme: theme, warning: true),
          FilledButton(
            onPressed: () => unawaited(_open()),
            child: const Text(DrivePairingScreen.freshCodeLabel),
          ),
        ];
    }
  }

  /// A phone's or a desktop's half: the page is already open, and a way to
  /// open it again for a launch that did not take or a tab that was closed.
  List<Widget> _openedSession(DrivePairingSession session, ThemeData theme) => [
    _Line(DrivePairingScreen.inBrowserMessage, theme: theme),
    OutlinedButton.icon(
      onPressed: () => unawaited(openInBrowser(context, session.link)),
      icon: const Icon(Icons.open_in_new),
      label: const Text(DrivePairingScreen.openAgainLabel),
    ),
  ];
}

/// The QR for a pairing link, with the quiet zone a camera needs.
///
/// A widget of this app's own rather than `QrImageView` bare, for two
/// reasons. The white margin is not decoration: a QR painted straight onto
/// this app's near-black surface has no light zone round it, and a phone
/// held up to one simply never locks on -- so the padding and the white
/// behind it are part of the thing being drawn. And it puts the link on a
/// field a test can read: `QrImageView` keeps its own data private, so a
/// test that could only find the library's widget could say a QR was drawn
/// and not that it was drawn for *this* session.
class PairingQrCode extends StatelessWidget {
  const PairingQrCode({super.key, required this.link, this.size = 240});

  /// What the QR encodes: `/link?s=<sessionId>` on the pairing service.
  final String link;

  /// The modules' box, not counting the quiet zone round it. 240 is read
  /// across a living room off a 720p panel, which is the smallest this app
  /// lays out for.
  final double size;

  /// The quiet zone, in logical pixels on each side.
  static const double quietZone = 12;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(quietZone),
    decoration: const BoxDecoration(
      color: Color(0xFFFFFFFF),
      borderRadius: BorderRadius.all(Radius.circular(8)),
    ),
    child: QrImageView(
      data: link,
      size: size,
      // The padding above is the quiet zone; a second one inside would
      // only shrink the modules within the same box.
      padding: EdgeInsets.zero,
      backgroundColor: const Color(0xFFFFFFFF),
    ),
  );
}

/// One paragraph, centred, in the one style this screen uses for prose.
class _Line extends StatelessWidget {
  const _Line(
    this.text, {
    required this.theme,
    this.quiet = false,
    this.warning = false,
  });

  final String text;
  final ThemeData theme;

  /// The footnote weight: what the window lasts, which is true and not
  /// urgent.
  final bool quiet;

  /// Something went wrong, or something about this pairing is less than it
  /// looks. Drawn in the error colour rather than merely worded carefully,
  /// because the case it exists for is a viewer glancing at a television
  /// from an armchair.
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Text(
      text,
      textAlign: TextAlign.center,
      style: (quiet ? theme.textTheme.bodySmall : theme.textTheme.bodyLarge)
          ?.copyWith(
            color: warning
                ? scheme.error
                : quiet
                ? scheme.onSurfaceVariant
                : null,
          ),
    );
  }
}
