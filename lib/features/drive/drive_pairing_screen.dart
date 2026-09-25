import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/external_link.dart';
import '../player/player_screen.dart';

/// Linking one file in somebody's Google Drive to this device, which is a
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
/// for the link, and the six-character code under it for a camera that will
/// not focus -- because nothing on that screen can be typed into and the
/// second device is the point. On a phone or a desktop there is no second
/// device, and scanning your own screen is absurd, so the app opens the link
/// itself and waits for the same answer. That is the split this app makes
/// everywhere ([DeviceScope.isTv]); the service knows nothing about it.
///
/// **The browser is the system's, never a web view.** Google refuses OAuth
/// in an embedded user agent (`disallowed_useragent`), so
/// `LaunchMode.inAppWebView` would not fail at the end of the flow but at
/// the start of it, on the sign-in page. The link goes out through
/// [openInBrowser], which is [UrlLauncherLinkOpener] and hard-codes
/// `LaunchMode.externalApplication`.
///
/// **`app_links` is deliberately not used to bring the app back.** It is
/// already a dependency and already handles deep links, and it was
/// considered for exactly this: a redirect at the end of the pick that puts
/// the app back in front. It is not worth it, for four reasons and not one.
/// The app never stops polling while the browser is over it, so by the time
/// the viewer comes back by themselves the screen already says "linked" --
/// what a hand-back would save is one Back press. The redirect would have to
/// come from the service, and the brief for this flow is that the service
/// needs no change. A `stremio://` link already means exactly one thing in
/// this app -- open that addon's details screen, install nothing
/// (`AGENTS.md`, "Deep links open an addon") -- and a second meaning on a
/// channel the platform hands to anybody is a second thing to get wrong.
/// And `app_links` replays the launch link on a cold start, so a pairing
/// hand-back kept by the platform would reopen this screen days later for a
/// session that no longer exists.
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
/// from the response object into [DriveAccount.linkFile] in one statement
/// and is in no field of this state. What the screen draws about a finished
/// pairing is the file's name. And [DriveLinkOutcome.thisRunOnly] -- the
/// secure store refusing the write -- is said out loud rather than dressed
/// up as success: the pairing works now and will be gone after a restart,
/// which is a thing a viewer would want to know before they settle in.
class DrivePairingScreen extends StatefulWidget {
  const DrivePairingScreen({
    super.key,
    this.service = const XtremioDrivePairingService(),
    this.opener = const ServerDriveFileOpener(),
    this.pollEvery = defaultPollEvery,
    this.now = DateTime.now,
  });

  /// Where the sessions come from; a widget test hands in a fake rather
  /// than reaching the deployed service.
  final DrivePairingService service;

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
  static const String title = 'Link a file';
  static const String scanHeading = 'Scan this with your phone';
  static const String browserHeading = 'Finish this in your browser';
  static const String codeLabel = 'Code';
  static const String openingMessage = 'Asking for a code…';
  static const String waitingMessage = 'Waiting for your phone…';
  static const String signedInMessage = 'Signed in. Now pick a file.';
  static const String windowMessage = 'This lasts about ten minutes.';
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
  static const String linkedFilesHeading = 'Files linked to this device';
  static const String linkAnotherLabel = 'Link another file';
  static const String openingFileMessage = 'Opening that file…';

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
enum _Stage {
  /// Asking the service for a session.
  opening,

  /// This device is already linked and has files. **The temporary way in**:
  /// until a Drive file has a row on the board of its own -- which wants
  /// filenames matched against Cinemeta, and is not this change -- the list
  /// a pairing built is the only place one can be played from, and this
  /// screen is where that list lives. A viewer who came here to link
  /// another file presses the button for it.
  files,

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

  /// What was linked, for the screen to name -- and nothing else about the
  /// pairing is kept, least of all the credential.
  String _linkedName = '';

  /// Which file the pairing linked, so the Play button on [_Stage.linked]
  /// aims at the row in the account's own list rather than at a copy of it.
  /// The id and not the row: the account is the record, and a row held here
  /// would be the second one.
  String _linkedFileId = '';
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
    if (_stage != _Stage.opening || _session != null || _opening) return;
    // A device that is already linked and has files opens on the list
    // rather than on a code: the commonest reason to come here after the
    // first time is to play something, and asking the service for a session
    // nobody wanted spends the one call it rate-limits. "Link another file"
    // is the way on, and a pairing that has died goes straight to a code --
    // the list is no use without a credential.
    if (account.state == DriveLinkState.linked && account.files.isNotEmpty) {
      _stage = _Stage.files;
      return;
    }
    // The first session is asked for once the scope is in reach, not in
    // `initState`, for exactly that reason.
    unawaited(_open());
  }

  @override
  void dispose() {
    // Leaving the screen stops the asking. The answer to a poll already out
    // is still handed over (see the class comment); what stops is arming
    // another one.
    _poll?.cancel();
    _window?.cancel();
    super.dispose();
  }

  /// Asks for a session and starts the waiting, or says why it could not.
  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    _poll?.cancel();
    _window?.cancel();
    if (mounted) {
      setState(() {
        _stage = _Stage.opening;
        _session = null;
        _signedIn = false;
        _refusal = '';
      });
    }
    final opening = await widget.service.open();
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
        // A phone has no second screen to scan with, so the app is the one
        // that opens the page. Once, here, rather than on every rebuild.
        if (!DeviceScope.isTv(context)) {
          await openInBrowser(context, session.link);
        }
    }
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
    // One statement, from the response into the account. The token is in no
    // field of this state and in no line of the log.
    final outcome = await account.linkFile(
      refreshToken: collected.refreshToken,
      fileId: collected.fileId,
      name: collected.name,
      mimeType: collected.mimeType,
    );
    if (!mounted) return;
    setState(() {
      _stage = _Stage.linked;
      _linkedName = collected.name;
      _linkedFileId = collected.fileId;
      _thisRunOnly = outcome == DriveLinkOutcome.thisRunOnly;
    });
  }

  /// One row per linked file, most recently linked first, each a way into
  /// the film.
  List<Widget> _fileRows() => [
    for (final file in _account?.files.entries ?? const <LinkedDriveFile>[])
      ListTile(
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
      ),
  ];

  /// Opens [file] on the embedded server and pushes the player at it.
  ///
  /// The whole of what this knows about the credential is that it does not
  /// have it: [openLinkedDriveFile] asks the account, which is the only
  /// thing that holds one. A dead pairing is written down in there too, so
  /// what is left here is a sentence and a code to scan -- the account's
  /// state is already [DriveLinkState.pairAgain] by the time this draws,
  /// and the list it was drawing is no longer any use.
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
          // The grant is gone, so the list is a list of films this device
          // cannot read: a code is the only thing left to offer.
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
            isTv
                ? DrivePairingScreen.scanHeading
                : DrivePairingScreen.browserHeading,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          if (isTv)
            ..._drawnSession(session, theme)
          else
            ..._openedSession(session, theme),
          _Line(
            _signedIn
                ? DrivePairingScreen.signedInMessage
                : DrivePairingScreen.waitingMessage,
            theme: theme,
          ),
          _Line(DrivePairingScreen.windowMessage, theme: theme, quiet: true),
        ];
      case _Stage.files:
        return [
          Text(
            DrivePairingScreen.linkedFilesHeading,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          if (_refusal.isNotEmpty) _Line(_refusal, theme: theme, warning: true),
          if (_playing)
            _Line(DrivePairingScreen.openingFileMessage, theme: theme),
          ..._fileRows(),
          OutlinedButton.icon(
            onPressed: () => unawaited(_open()),
            icon: const Icon(Icons.add_link),
            label: const Text(DrivePairingScreen.linkAnotherLabel),
          ),
        ];
      case _Stage.linked:
        final justLinked = _account?.files.forFile(_linkedFileId);
        return [
          Icon(
            Icons.check_circle_outline,
            size: 40,
            color: theme.colorScheme.primary,
          ),
          Text(
            _linkedName.isEmpty
                ? 'That file is linked.'
                : '"$_linkedName" is linked.',
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
          // remote and certainly means to watch that file.
          if (justLinked != null)
            FilledButton.icon(
              onPressed: _playing ? null : () => unawaited(_play(justLinked)),
              icon: const Icon(Icons.play_arrow),
              label: const Text(DrivePairingScreen.playLabel),
            ),
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

  /// A television's half: the QR, and the code under it.
  List<Widget> _drawnSession(DrivePairingSession session, ThemeData theme) => [
    PairingQrCode(link: session.link),
    if (session.code.isNotEmpty)
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            DrivePairingScreen.codeLabel,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            session.code,
            key: pairingCodeKey,
            style: theme.textTheme.headlineMedium?.copyWith(
              letterSpacing: 6,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
  ];

  /// A phone's or a desktop's half: the page is already open, and a way to
  /// open it again for a launch that did not take or a tab that was closed.
  List<Widget> _openedSession(DrivePairingSession session, ThemeData theme) => [
    _Line(
      'Sign in to Google in the page that opened and pick the file you want. '
      'This screen is watching for it.',
      theme: theme,
    ),
    OutlinedButton.icon(
      onPressed: () => unawaited(openInBrowser(context, session.link)),
      icon: const Icon(Icons.open_in_new),
      label: const Text(DrivePairingScreen.openAgainLabel),
    ),
  ];
}

/// The key on the code drawn beneath the QR.
const Key pairingCodeKey = Key('drive-pairing-code');

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
