import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/tv_density.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/remote_press.dart';
import '../downloads/download_labels.dart';
import 'idle_sharing.dart';
import 'sharing_activity.dart';

/// The status light that says Xtremio is using this device's connection
/// while nothing is playing.
///
/// **It says what is happening, never what is allowed.** It is drawn only
/// while [SharingActivityMonitor.active] -- the server measured bytes
/// moving to or from peers over the last window, with no player reading --
/// and never because the setting is on. An icon that is on whenever the
/// switch is on says nothing and becomes furniture, and the point of the
/// whole change it belongs to is that seeing the traffic is the control.
///
/// **One slot, three glyphs.** An up arrow while bytes go out (serving other
/// people), a down arrow while they come in (an offline download filling
/// in, or the title you last played fetching what it keeps), and one glyph with
/// both arrows while both are true -- never two lights, because two pulsing
/// things fight the brief of a discreet status light. What is lit is the
/// server's own halves ([BackgroundTraffic.uploading] and
/// [BackgroundTraffic.downloading]), judged on the Rust side over one
/// sample with "nothing playing" already folded in; see [glyphFor].
///
/// **And only while the shell is what is on screen.** The server already
/// answers dark while a player is reading, so this is not what keeps the
/// light off during a film. It is what keeps the polling from costing
/// anything while nobody could see the light: it is drawn by `RootShell`,
/// and its route stops being the current one the moment a player (or
/// anything else) is pushed over it, so it appears on the five shell
/// screens and nowhere else -- not over the details or downloads screens
/// either, which is a silence rather than a lie. That is also where the
/// polling stops; see [SharingActivityMonitor].
///
/// **On a television the remote reaches it from the rail.** The node the
/// shell hands in is skipped by traversal, so the light can never stand
/// between a D-pad press and the poster it was meant for; what reaches it is
/// one explicit rule of the shell's (`_onRailKey`), up from the top of the
/// rail, which was a key that did nothing before. Any direction key hands the remote straight back
/// to the rail, so the ring can never be stranded on a light that goes out.
/// Off a television it is an ordinary button: a pointer presses it, and Tab
/// reaches it.
///
/// **It is a light, not a notification.** Semi-transparent, and pulsing
/// slowly enough that nothing pulls the eye during a poster row -- and not
/// pulsing at all where the platform says animations are off.
class SharingLight extends StatefulWidget {
  const SharingLight({super.key, required this.focusNode, this.onLeave});

  /// The node the shell owns, so it can put focus here from the rail.
  final FocusNode focusNode;

  /// A direction key was pressed while the light held focus: the shell
  /// takes the remote back. Null off a television, where nothing needs it.
  final VoidCallback? onLeave;

  /// The three glyphs: up while bytes go out, down while they come in, both
  /// arrows while both. The up arrow is the settings switch's own icon,
  /// since serving other people is what that switch is about.
  static const IconData uploadingIcon = Icons.upload_outlined;
  static const IconData downloadingIcon = Icons.download_outlined;
  static const IconData bothIcon = Icons.swap_vert;

  /// Which glyph [reading] lights, or null when it lights none -- which is
  /// when the light is not drawn at all.
  static IconData? glyphFor(BackgroundTraffic reading) =>
      switch ((up: reading.uploading, down: reading.downloading)) {
        (up: true, down: true) => bothIcon,
        (up: true, down: false) => uploadingIcon,
        (up: false, down: true) => downloadingIcon,
        (up: false, down: false) => null,
      };

  /// What a viewer hears for [reading], what a pointer's tooltip says, and
  /// the popup's title: which way the bytes are going.
  static String labelFor(BackgroundTraffic reading) =>
      switch ((up: reading.uploading, down: reading.downloading)) {
        (up: true, down: true) => 'Uploading and downloading',
        (up: true, down: false) => 'Uploading to other people',
        _ => 'Downloading',
      };

  /// The one sentence the popup opens with, in the words the light means.
  /// No numbers: the reading carries the sums a verdict was judged from, not
  /// a rate, and a total over whichever torrents exist right now is not a
  /// figure a viewer can do anything with.
  static const String summary =
      'Xtremio is using your connection while nothing is playing.';

  /// How long one half of the pulse takes. Slow: a status light is meant to
  /// be noticeable when looked for and ignorable when not, and anything
  /// quicker than this reads as something asking to be dealt with.
  static const Duration pulse = Duration(milliseconds: 1600);

  /// The two ends of the pulse. Neither is opaque -- it is drawn over
  /// poster art and must not compete with it -- and the dimmer end stays
  /// well clear of invisible, so the light is still there between beats.
  static const double dimmest = 0.35;
  static const double brightest = 0.8;

  @override
  State<SharingLight> createState() => _SharingLightState();
}

class _SharingLightState extends State<SharingLight> {
  bool _focused = false;

  /// The monitor this is currently watching through, so the watch is turned
  /// off again on the way out.
  SharingActivityMonitor? _monitor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final monitor = SharingScope.of(context)?.monitor;
    // `ModalRoute.of` depends on the route's own inherited status, so this
    // runs again when something is pushed over the shell or popped off it.
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    if (monitor != _monitor) _monitor?.watching = false;
    _monitor = monitor;
    if (monitor == null) return;
    // After the frame, not in it: turning the watch off drops the last
    // reading and notifies, and a notification answered from inside a build
    // is a `markNeedsBuild` on an element the framework is already
    // building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _monitor == monitor) monitor.watching = onTop;
    });
  }

  @override
  void dispose() {
    _monitor?.watching = false;
    super.dispose();
  }

  /// A direction key on the light hands the remote back to the rail it came
  /// from. There is nothing to walk here -- it is one stop -- and a key that
  /// merely did nothing would leave the viewer pressing at a light with no
  /// way off it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final directional =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    if (!directional) return KeyEventResult.ignored;
    widget.onLeave?.call();
    return KeyEventResult.handled;
  }

  /// Opens the popup over the reading the light is lit by right now.
  ///
  /// While bytes are coming in, the offline downloads are listed first and
  /// handed to the dialog, so that what it draws is decided before it is
  /// drawn: a "Cancel" row is offered per download still on its way, and a
  /// dialog that listed them after opening would change shape under the
  /// viewer, or draw a row for a download that turns out not to exist. A
  /// listing that fails is an empty list -- the popup then says no offline
  /// download is in flight, which is all the app knows.
  Future<void> _open() async {
    final scope = SharingScope.read(context);
    if (scope == null) return;
    final reading = scope.monitor.reading;
    var downloads = const <DownloadView>[];
    if (reading.downloading) {
      final client = context
          .getInheritedWidgetOfExactType<DownloadsScope>()
          ?.client;
      if (client != null) {
        try {
          downloads = [
            for (final view in (await client.list()).newestFirst)
              if (view.isUnfinished) view,
          ];
        } catch (_) {
          downloads = const [];
        }
      }
      if (!mounted) return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) =>
          SharingStopDialog(traffic: reading, downloads: downloads),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = SharingScope.of(context);
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    final reading = scope?.monitor.reading ?? BackgroundTraffic.none;
    final glyph = SharingLight.glyphFor(reading);
    if (glyph == null || !onTop) return const SizedBox.shrink();
    final label = SharingLight.labelFor(reading);
    final isTv = DeviceScope.isTv(context);
    final size = isTv ? TvDensity.minTarget : 40.0;
    final light = Semantics(
      button: true,
      label: label,
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: _Pulse(
            child: Icon(
              glyph,
              size: isTv ? 28 : 20,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );

    if (!isTv) {
      return Tooltip(
        message: label,
        child: InkWell(
          key: const Key('sharing-light'),
          customBorder: const CircleBorder(),
          onTap: _open,
          child: light,
        ),
      );
    }
    // The ring alone: it is one surface with nothing of its own kind beside
    // it, so bold's dimming would only fade it out on its own -- the seek
    // bar's reason, and what [FocusTreatment.readout] is for.
    return RemotePress(
      onTap: _open,
      child: Focus(
        key: const Key('sharing-light'),
        focusNode: widget.focusNode,
        onKeyEvent: _onKey,
        onFocusChange: (focused) {
          if (mounted && focused != _focused) {
            setState(() => _focused = focused);
          }
        },
        child: FocusHighlight(
          focused: _focused,
          treatment: FocusTreatment.readout,
          borderRadius: BorderRadius.all(Radius.circular(size / 2)),
          child: light,
        ),
      ),
    );
  }
}

/// [child] fading slowly in and out between [SharingLight.dimmest] and
/// [SharingLight.brightest], for as long as it is on screen.
///
/// A widget of its own so that nothing starts or stops an animation from
/// inside a build: the pulse runs while this is mounted and stops when it is
/// taken away, which is exactly when the light is drawn and not.
///
/// A platform that has been asked for no animations gets the steady light
/// instead. That is also what lets a widget test settle, since a repeating
/// controller never does.
class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: SharingLight.pulse,
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: SharingLight.dimmest,
    end: SharingLight.brightest,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (still == _still && (still || _controller.isAnimating)) return;
    _still = still;
    if (still) {
      _controller.stop();
    } else {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _still
      ? Opacity(opacity: SharingLight.brightest, child: widget.child)
      : FadeTransition(opacity: _opacity, child: widget.child);
}

/// What pressing the light offers: the stops that apply to what is moving,
/// and one way out of the dialog having taken none of them.
///
/// **It offers a stop only where there is something for it to stop, and
/// every row with a press on it does something.** The light is drawn from
/// the server's measured halves (see [SharingLight]), so the dialog is
/// built from the same two halves and from what each one's stop governs:
///
/// - **Bytes going out** are what "Share while idle" governs, so the
///   sharing rows are drawn: "Not now" ([IdleSharingPolicy.pauseUntilRestart])
///   and "Stop sharing" (the setting). The server obeys either at its next
///   pass, every two seconds, and the light's sample can still hold bytes
///   from before that, so it is honestly lit for a moment in two states
///   where a stop has no answer. With the switch already off both rows
///   would be dead (a pause of a setting that is off, a switch turned off
///   that is off), so the dialog says that ([IdleSharing.alreadyOffTitle])
///   and offers neither; with a "Not now" already in force the pause row
///   alone is dead, since the policy takes no second pause, so the dialog
///   says the pause is in force ([IdleSharing.pausedTitle]) and offers only
///   the switch. The pause is read from [IdleSharingPolicy.pausedForRun],
///   not inferred from the light, which cannot tell.
/// - **Bytes coming in** are either an offline download filling in or the
///   title you last played fetching what it keeps. The first is governed by the
///   downloads: one "Cancel" row per download still on its way
///   ([downloads], listed by the light as it opened), each of which drops
///   that download and its part-file through [DownloadsClient.remove] --
///   what "Cancel all" on the downloads notification does, since there is
///   no pause for a pinned file. With no offline download in flight the
///   bytes are the second thing, which nothing here governs: the sharing
///   setting switches uploading only, and the title stops fetching by
///   itself once it holds what it keeps, or when something else is played.
///   So the dialog says so ([noDownloadTitle]) and draws no stop at all --
///   the sharing rows beside it would read as the way to stop bytes they
///   do not touch.
/// - **Both** draws both groups, each under a heading, so the viewer can
///   tell which row is about which arrow.
///
/// The rows are drawn as list rows with a line each rather than as
/// buttons, because two stops that differ in exactly one thing -- how long
/// they last -- would leave that difference to be guessed at from a pair of
/// button labels. The dialog's one action is its way out, "Close", which
/// changes nothing; Back (or the barrier) is the same answer.
class SharingStopDialog extends StatelessWidget {
  const SharingStopDialog({
    super.key,
    required this.traffic,
    this.downloads = const [],
  });

  /// The reading the light was lit by when it was pressed.
  final BackgroundTraffic traffic;

  /// The offline downloads still on their way when the light was pressed
  /// ([DownloadView.isUnfinished]), newest first. Read only while
  /// [traffic] says bytes are coming in; a "Cancel" row is drawn for each.
  final List<DownloadView> downloads;

  /// Keys a test presses, and the only names these rows answer to. A stop
  /// is drawn only while it would do something; [closeKey] is the way out
  /// and is always there.
  static const Key notNowKey = Key('sharing-not-now');
  static const Key stopKey = Key('sharing-stop');
  static const Key pausedKey = Key('sharing-paused');
  static const Key alreadyOffKey = Key('sharing-already-off');
  static const Key noDownloadKey = Key('sharing-no-download');
  static const Key closeKey = Key('sharing-close');

  /// The "Cancel" row for the download under [key]
  /// ([DownloadView.key]).
  static Key cancelKey(String key) => Key('sharing-cancel-$key');

  /// The headings over the two groups, drawn only when both are.
  static const String uploadingHeading = 'Uploading';
  static const String downloadingHeading = 'Downloading';

  /// What the download group says when bytes are coming in and no offline
  /// download is on its way: the only other thing the server downloads with
  /// nothing playing is the title last played, which stays the live one
  /// until something else is and fetches what the server keeps of it for a
  /// resume. Nothing in the app stops that, and nothing needs to, so this
  /// says what it is and that it ends.
  static const String noDownloadTitle = 'No offline download is in flight';
  static const String noDownloadDescription =
      'What is arriving is the title you last played, fetching what it '
      'keeps for you to carry on watching. It stops by itself.';

  /// What the "Cancel" row costs, on the row: the download stops being kept
  /// and its part-file goes, the same as the downloads notification's
  /// "Cancel all". A download the server has not started yet has nothing to
  /// delete, and the row says that instead of naming a size of nothing.
  static String cancelDescription(DownloadView view) => view.downloaded > 0
      ? 'Stops keeping it offline and deletes the ${view.downloadedLabel} '
            'that has arrived so far.'
      : 'Stops keeping it offline. Nothing has arrived yet.';

  /// What is said when the removal itself failed, after the dialog has
  /// closed; the download is then still listed and still downloading.
  static const String cancelFailed = 'This download could not be cancelled.';

  @override
  Widget build(BuildContext context) {
    final scope = SharingScope.read(context);
    final prefs = PrefsScope.maybeOf(context);
    final downloadsClient = DownloadsScope.maybeOf(context);
    // Both the preference and the policy's pause, because the light answers
    // neither: it is lit by measured bytes, which can outlast either for a
    // moment. A pause is a state of a switch that is on (the policy holds
    // that from both ends), so `paused` implies `sharing`.
    final sharing = prefs?.shareWhileIdle ?? false;
    final paused = sharing && (scope?.policy.pausedForRun ?? false);
    // A "Cancel" row is only a row that does something with a client to
    // press it on; without one the downloads are treated as not listed.
    final cancellable = downloadsClient == null
        ? const <DownloadView>[]
        : downloads;
    final uploading = traffic.uploading;
    final downloading = traffic.downloading;
    // The sharing rows govern the uploading and nothing else (see the class
    // comment).
    final showSharing = uploading;
    final both = uploading && downloading;

    final sharingRows = <Widget>[
      if (!sharing)
        ListTile(
          key: alreadyOffKey,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.do_not_disturb_on_outlined),
          title: const Text(IdleSharing.alreadyOffTitle),
          subtitle: const Text(IdleSharing.alreadyOffDescription),
        )
      else if (paused) ...[
        // The pause is said rather than offered: `pauseUntilRestart` takes
        // no second pause, so a "Not now" row here would be drawn and dead.
        // The switch is the one stop left with something to do.
        ListTile(
          key: pausedKey,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.pause_circle_outline),
          title: const Text(IdleSharing.pausedTitle),
          subtitle: const Text(IdleSharing.pausedDescription),
        ),
        _stopRow(context, prefs),
      ] else ...[
        ListTile(
          key: notNowKey,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.pause_circle_outline),
          title: const Text(IdleSharing.pauseTitle),
          subtitle: const Text(IdleSharing.pauseDescription),
          onTap: () {
            scope?.policy.pauseUntilRestart();
            Navigator.of(context).pop();
          },
        ),
        _stopRow(context, prefs),
      ],
    ];

    final downloadRows = <Widget>[
      if (cancellable.isEmpty)
        const ListTile(
          key: noDownloadKey,
          contentPadding: EdgeInsets.zero,
          leading: Icon(SharingLight.downloadingIcon),
          title: Text(noDownloadTitle),
          subtitle: Text(noDownloadDescription),
        )
      else
        for (final view in cancellable)
          ListTile(
            key: cancelKey(view.key),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cancel_outlined),
            title: Text('Cancel ${view.name}'),
            subtitle: Text(cancelDescription(view)),
            onTap: () => _cancel(context, downloadsClient!, view),
          ),
    ];

    return AlertDialog(
      // Several downloads in flight make more rows than a short screen
      // holds, and the way out is under them.
      scrollable: true,
      title: Text(SharingLight.labelFor(traffic)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(SharingLight.summary),
          const SizedBox(height: 12),
          // With both arrows lit each group has its heading.
          if (both) _heading(context, uploadingHeading),
          if (showSharing) ...sharingRows,
          if (both) _heading(context, downloadingHeading),
          if (downloading) ...downloadRows,
        ],
      ),
      actions: [
        TextButton(
          key: closeKey,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  /// "Stop sharing": the same preference the settings switch writes, so the
  /// one policy sends it on and the server has one author either way.
  Widget _stopRow(BuildContext context, AppPrefs? prefs) => ListTile(
    key: stopKey,
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.do_not_disturb_on_outlined),
    title: const Text(IdleSharing.stopTitle),
    subtitle: const Text(IdleSharing.stopDescription),
    onTap: () {
      prefs?.setShareWhileIdle(false);
      Navigator.of(context).pop();
    },
  );

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  /// Drops [view] and its part-file, the way the downloads notification's
  /// "Cancel all" does, and says what happened where the shell can show it.
  /// The dialog closes first: the removal is a round trip to the server,
  /// and a row that stays on screen after it was pressed is a row that
  /// looks like it did nothing.
  Future<void> _cancel(
    BuildContext context,
    DownloadsClient client,
    DownloadView view,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    String message;
    try {
      final result = await client.remove(view.key, deleteFiles: true);
      message = downloadRemovedMessage(result, view);
    } catch (_) {
      message = cancelFailed;
    }
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}
