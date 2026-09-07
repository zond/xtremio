import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/tv_density.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/remote_press.dart';
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
/// in, or a title you watched finishing its own file), and one glyph with
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

  Future<void> _open() async {
    final scope = SharingScope.read(context);
    if (scope == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => SharingStopDialog(traffic: scope.monitor.reading),
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

/// What pressing the light offers: the stops that apply to what is going
/// out, and one way out of the dialog having taken none of them.
///
/// **It offers a stop only where there is something for it to stop.** The
/// light is drawn from bytes measured leaving the device and never from the
/// setting (see [SharingLight]), so it is lit in two states a stop has no
/// answer for, because things upload that neither stop governs: a torrent
/// serving out its idle grace, and a title kept offline. With "Share while
/// idle" already off both stops are dead -- a "Not now" would pause a
/// setting that is off and "Stop sharing" would turn off a switch that is
/// off -- so the dialog says that instead ([IdleSharing.alreadyOffTitle])
/// and offers neither. With the switch on and a "Not now" already in force
/// the pause row alone is dead: the policy takes no second pause, and a row
/// that is drawn and does nothing when pressed is the same defect as a
/// button drawn and dead. So the dialog says the pause is in force
/// ([IdleSharing.pausedTitle]) and offers only the switch, which still
/// does something because it is the longer of the two stops. The dismiss
/// action says "Keep sharing" only where a stop was offered and declined;
/// where nothing was, it says "Close", since nothing is being kept.
///
/// The pause is read from [IdleSharingPolicy.pausedForRun] and not inferred
/// from the light, because the light says nothing about it: the server was
/// told to stop, and the bytes the light measures are the grace and the
/// pinned titles, exactly what a pause cannot reach. That is why a pause
/// and a lit light are an ordinary pair rather than an edge.
///
/// That the rows are chosen by what is running rather than always drawn is
/// what this will be widened along: the light is coming to mean "Xtremio is
/// using your connection while you are not watching", a background download
/// lighting it as much as a share does, and the dialog will then have to
/// name which of the two is going on and offer that one's stop.
///
/// The two stops are drawn as rows with a line each rather than as buttons,
/// because they differ in exactly one thing -- how long they last -- and a
/// pair of buttons labelled "Not now" and "Stop sharing" would leave that
/// difference to be guessed at. The dialog's one action is its way out, and
/// Back (or the barrier) is the same answer.
class SharingStopDialog extends StatelessWidget {
  const SharingStopDialog({super.key, required this.traffic});

  /// The reading the light was lit by when it was pressed.
  final BackgroundTraffic traffic;

  /// Keys a test presses, and the only names these rows answer to. A stop
  /// is drawn only while it would do something -- both with the setting on
  /// and no pause in force, the switch alone under a pause, neither with the
  /// setting off; [keepKey] is the way out and is always there.
  static const Key notNowKey = Key('sharing-not-now');
  static const Key stopKey = Key('sharing-stop');
  static const Key pausedKey = Key('sharing-paused');
  static const Key alreadyOffKey = Key('sharing-already-off');
  static const Key keepKey = Key('sharing-keep');

  @override
  Widget build(BuildContext context) {
    final scope = SharingScope.read(context);
    final prefs = PrefsScope.maybeOf(context);
    // Both the preference and the policy's pause, because the light answers
    // neither: it is lit by measured bytes, and a torrent's idle grace and a
    // pinned title go on uploading with the switch off and under a pause
    // alike. A pause is a state of a switch that is on (the policy holds
    // that from both ends), so `paused` implies `sharing`.
    final sharing = prefs?.shareWhileIdle ?? false;
    final paused = sharing && (scope?.policy.pausedForRun ?? false);
    final stopRow = ListTile(
      key: stopKey,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.do_not_disturb_on_outlined),
      title: const Text(IdleSharing.stopTitle),
      subtitle: const Text(IdleSharing.stopDescription),
      onTap: () {
        // The same preference the settings switch writes, so the one
        // policy sends it on and the server has one author either way.
        prefs?.setShareWhileIdle(false);
        Navigator.of(context).pop();
      },
    );
    return AlertDialog(
      title: Text(SharingLight.labelFor(traffic)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(SharingLight.summary),
          const SizedBox(height: 12),
          if (!sharing)
            ListTile(
              key: alreadyOffKey,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.do_not_disturb_on_outlined),
              title: const Text(IdleSharing.alreadyOffTitle),
              subtitle: const Text(IdleSharing.alreadyOffDescription),
            )
          else if (paused) ...[
            // The pause is said rather than offered: `pauseUntilRestart`
            // takes no second pause, so a "Not now" row here would be drawn
            // and dead. The switch is the one stop left with something to
            // do.
            ListTile(
              key: pausedKey,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.pause_circle_outline),
              title: const Text(IdleSharing.pausedTitle),
              subtitle: const Text(IdleSharing.pausedDescription),
            ),
            stopRow,
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
            stopRow,
          ],
        ],
      ),
      actions: [
        TextButton(
          key: keepKey,
          onPressed: () => Navigator.of(context).pop(),
          // "Keep sharing" only where leaving keeps a sharing this dialog
          // offered to stop. With the switch off nothing is being kept, and
          // under a pause the sharing has already been stopped -- what goes
          // on is what neither stop reaches -- so leaving is only leaving.
          child: Text(sharing && !paused ? 'Keep sharing' : 'Close'),
        ),
      ],
    );
  }
}
