import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shell/device_profile.dart';
import '../../shell/tv_density.dart';
import '../../widgets/remote_press.dart';
import 'subtitle_match.dart';

/// What a viewer has asked of the subtitles' timing: a measured
/// multiplier and offset, and the presses they have made on top.
///
/// Two quantities, because there are two ways a file can be out. A
/// **shift** answers a subtitle cut for a release that starts somewhere
/// else -- a distributor logo this video does not have. A **stretch**
/// answers a rate that drifts.
///
/// Nothing else writes either property, so what is in this is the whole
/// of what mpv is playing: a declared frame rate is a claim about the
/// release an upload was made for, and the same claim covers files that
/// keep time and files that do not, so acting on it fixes one and breaks
/// the other in equal measure. What the viewer *observes* is the only
/// thing that tells those apart, and there are two ways to observe it --
/// marking the picture right (`SubtitleCalibration`) and matching
/// against a file they say is in sync (`SubtitleMatchClient`). Both
/// solve for [calibratedSpeed] and [calibratedDelay].
///
/// The presses are counted as integers so that ten forward and ten back
/// land exactly where they started; a double accumulated a tenth at a
/// time does not. They count *on top of* the measured offset rather than
/// into it, so a nudge after a measurement still comes back to the
/// measured value exactly.
@immutable
final class SubtitleTiming {
  const SubtitleTiming({
    this.shiftSteps = 0,
    this.calibratedSpeed,
    this.calibratedDelay,
  });

  /// Presses of the shift control, positive being later. A press is
  /// worth [shiftStep], and a held button hands over several at a time
  /// ([SubtitleTimingOverlay.shiftStrideAt]).
  final int shiftSteps;

  /// The multiplier a measurement solved for, and null for the file's
  /// own timing.
  ///
  /// A measurement and not a menu of values: the owner's own Swedish
  /// file wants 1.0440 where the PAL constant is 1.0427, which is three
  /// seconds across an episode. The toggle that offered the constant and
  /// its reciprocal is gone for exactly that reason -- it was too blunt
  /// for the case it was written for.
  final double? calibratedSpeed;

  /// The offset a measurement solved for, in seconds, and null when none
  /// has been made.
  final double? calibratedDelay;

  /// One press of the shift control. A tenth of a second is about the
  /// smallest offset that is visible against speech and small enough that
  /// holding the key is how a two-second correction gets made.
  static const double shiftStep = 0.1;

  /// The offset for libmpv's `sub-delay`, in seconds. Positive delays the
  /// lines, which is mpv's own sign.
  double get delay => (calibratedDelay ?? 0) + shiftSteps * shiftStep;

  /// The multiplier for libmpv's `sub-speed`, and 1.0 -- the file's own
  /// timing -- until something has measured otherwise.
  double get speed => calibratedSpeed ?? 1;

  /// The viewer has touched something, so there is a correction of theirs
  /// to undo. Reset is offered for exactly this.
  bool get adjusted =>
      shiftSteps != 0 || calibratedSpeed != null || calibratedDelay != null;

  /// The offset as the overlay shows it: signed, because which way it has
  /// gone is the whole of what a viewer is tracking between presses.
  String get shiftText =>
      '${delay > 0 ? '+' : ''}${delay.toStringAsFixed(1)} s';

  /// The multiplier as the overlay shows it. Three decimals is what
  /// separates the correction from the file's own timing.
  String get speedText => '${speed.toStringAsFixed(3)}×';

  /// [steps] more presses of the shift control.
  SubtitleTiming shiftedBy(int steps) => SubtitleTiming(
    shiftSteps: shiftSteps + steps,
    calibratedSpeed: calibratedSpeed,
    calibratedDelay: calibratedDelay,
  );

  @override
  bool operator ==(Object other) =>
      other is SubtitleTiming &&
      other.shiftSteps == shiftSteps &&
      other.calibratedSpeed == calibratedSpeed &&
      other.calibratedDelay == calibratedDelay;

  @override
  int get hashCode => Object.hash(shiftSteps, calibratedSpeed, calibratedDelay);

  @override
  String toString() =>
      'SubtitleTiming(delay: $delay, speed: $speed, shift: $shiftSteps)';
}

/// The panel that drives a [SubtitleTiming]: a stepper, what a
/// measurement has put on the speed, and a reset.
///
/// It is deliberately not part of the player's OSD. Adjusting means
/// pressing, then watching the picture for several seconds to see what
/// the press did, and a panel on the OSD's three-second timer would be
/// gone before the first judgement was made. The screen draws this
/// outside the bar's fade and gives it its own rung on the Back ladder.
class SubtitleTimingOverlay extends StatelessWidget {
  const SubtitleTimingOverlay({
    super.key,
    required this.timing,
    required this.onShift,
    required this.onReset,
    required this.onClose,
    this.onMatch,
    this.matching = false,
    this.matchNote,
    this.firstFocusNode,
  });

  final SubtitleTiming timing;

  /// A press of the shift control, in presses of
  /// [SubtitleTiming.shiftStep] and signed: negative earlier, positive
  /// later. A tap is always `-1` or `1`; a hold hands over larger
  /// strides as it accelerates ([shiftStrideAt]).
  final ValueChanged<int> onShift;

  /// Back to untouched: speed 1.0, shift 0.0. With nothing else writing
  /// either property, "undo what I did" and "back to untouched" are the
  /// same thing.
  final VoidCallback onReset;
  final VoidCallback onClose;

  /// Opens the list of other subtitle files to measure this one against,
  /// and **null when there is no other file on offer** -- in which case
  /// nothing about matching is drawn at all. A control that cannot do
  /// anything is worse than one that is not there, and here it would be
  /// worse still: it would say the app has a way of fixing this that it
  /// does not have for this video.
  final VoidCallback? onMatch;

  /// Whether a measurement is running. Two HTTP fetches, so it is worth
  /// seconds on a slow connection and the panel says so rather than
  /// looking like a press that did nothing.
  final bool matching;

  /// What the last measurement said, and null when none has been made
  /// against the file on screen. The count is shown whichever way it
  /// went: it is the evidence for applying the transform, and the
  /// evidence for refusing to.
  final String? matchNote;

  /// Attached to the first button: where the remote lands when the panel
  /// opens.
  final FocusNode? firstFocusNode;

  static const String title = 'Subtitle timing';

  /// The primary action, above the manual controls: the two mechanisms
  /// fix the same thing, and this one measures where the steppers guess.
  static const String matchLabel = 'Match to another subtitle';
  static const String shiftLabel = 'Shift';
  static const String speedLabel = 'Speed';
  static const String resetLabel = 'Reset';

  /// Wide enough for the widest row at the television's text scale, and
  /// fixed so that a number growing a digit does not move the buttons the
  /// remote is sitting on.
  static const double width = 300;

  /// How long the shift stepper has to be held before it starts
  /// repeating.
  static const Duration holdDelay = Duration(milliseconds: 400);

  /// How often it steps after that: fast enough that a two-second shift
  /// is a couple of seconds of holding, slow enough to let go on a value.
  static const Duration repeatInterval = Duration(milliseconds: 120);

  /// How many times a held shift button steps in tenths before it moves
  /// to whole seconds, and how many times in whole seconds before it
  /// moves to five-second strides.
  ///
  /// The offsets a viewer has to reach are three orders of magnitude
  /// apart, so one stride cannot serve them. A tenth is the smallest
  /// difference visible against speech; a subtitle cut for a release
  /// that starts somewhere else is out by seconds; and a file whose
  /// *rate* is wrong is out by minutes -- an uncorrected PAL file runs
  /// 4.27 % short, which over a three-quarter-hour episode is nearly
  /// two minutes by the end of it. Marking a point out there means
  /// shifting by that much, and at a tenth a step that is eleven
  /// hundred steps: over two minutes of holding the key down, which is
  /// not an adjustment anybody makes.
  ///
  /// Ten steps of a tenth cover the first second, fifteen steps of a
  /// second cover the next fifteen, and five-second strides after that
  /// put the whole of an episode's drift within about six seconds of
  /// holding.
  static const int tenthStrideSteps = 10;
  static const int secondStrideSteps = 15;

  /// What the [fire]th step of a held shift button is worth, counted in
  /// presses of [SubtitleTiming.shiftStep]: one tenth, then a whole
  /// second (ten of them), then five seconds (fifty).
  ///
  /// [fire] is 0 for the press itself and counts up for as long as the
  /// button is held, so **only a hold accelerates**. Every tap starts
  /// again at the first stride, which is what keeps a tenth reachable
  /// however large the correction before it was -- and what keeps ten
  /// forward and ten back landing on exactly nothing, since every
  /// stride is a whole number of presses.
  static int shiftStrideAt(int fire) {
    if (fire < tenthStrideSteps) return 1;
    if (fire < tenthStrideSteps + secondStrideSteps) return 10;
    return 50;
  }

  /// The ring the steppers wear, given to Reset and Close as a border of
  /// their own.
  ///
  /// Material's own focus for a [TextButton] or an [IconButton] is a
  /// 10 %-opacity overlay, and over this panel's near-black ground that
  /// is about 1.2:1 -- roughly an eighth of what the steppers' two
  /// pixels of [ColorScheme.primary] manage, and gone entirely at three
  /// metres on a lit screen. Two stops of the same panel cannot differ
  /// by that much: this is the surface meant to be operated *after* the
  /// OSD bar has faded, so the ring is the only thing saying what the
  /// centre key will press.
  static ButtonStyle focusRing(ColorScheme scheme) => ButtonStyle(
    side: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.focused)
          ? BorderSide(color: scheme.primary, width: 2)
          : BorderSide.none,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Opaque as a whole: the video below is a tap-to-toggle-the-OSD
    // surface with a double-tap-to-seek on it, and a press that misses a
    // button by a few pixels must not reach either.
    return Listener(
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('subtitle-timing-close'),
                      tooltip: 'Close',
                      color: Colors.white,
                      iconSize: 20,
                      style: focusRing(theme.colorScheme),
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                if (onMatch != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('subtitle-match'),
                      style: focusRing(theme.colorScheme),
                      // Disabled rather than hidden while one runs: a
                      // button that vanishes under the remote takes the
                      // focus ring with it.
                      onPressed: matching ? null : onMatch,
                      icon: const Icon(Icons.compare_arrows, size: 18),
                      label: const Text(matchLabel),
                    ),
                  ),
                if (matching || matchNote != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 8, 8),
                    child: Text(
                      key: const ValueKey('subtitle-match-note'),
                      matching ? subtitleMatchingNote : matchNote!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  ),
                _TimingRow(
                  label: shiftLabel,
                  value: timing.shiftText,
                  before: _PanelButton(
                    key: const ValueKey('subtitle-shift-earlier'),
                    icon: Icons.remove,
                    tooltip: 'Subtitles earlier',
                    focusNode: firstFocusNode,
                    onPress: (fire) => onShift(-shiftStrideAt(fire)),
                  ),
                  after: _PanelButton(
                    key: const ValueKey('subtitle-shift-later'),
                    icon: Icons.add,
                    tooltip: 'Subtitles later',
                    onPress: (fire) => onShift(shiftStrideAt(fire)),
                  ),
                ),
                // Read only: nothing here presses a multiplier any
                // more, and what is on it was measured rather than
                // judged. It is still shown, because the panel is the
                // surface operated after the OSD bar has faded and a
                // stretch in force is otherwise invisible -- a subtitle
                // that is right at this moment and wrong in ten minutes
                // looks exactly like one that is right. The two gaps
                // keep the number in the same column as the shift's.
                _TimingRow(
                  label: speedLabel,
                  value: timing.speedText,
                  before: const _ButtonGap(),
                  after: const _ButtonGap(),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const ValueKey('subtitle-timing-reset'),
                    style: focusRing(theme.colorScheme),
                    onPressed: timing.adjusted ? onReset : null,
                    child: const Text(resetLabel),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One labelled row: a control, the value it is showing, and a control.
///
/// Left and right along the row is the shape a remote expects, and it is
/// what directional traversal gives for free from the geometry -- which
/// is why the buttons are siblings in a `Row` and not something drawn
/// inside a focusable tile. Both rows share the layout so that the value
/// sits in one column and the buttons in two, whichever of them a row
/// has -- the speed row has neither, and draws two [_ButtonGap]s so its
/// number still lines up under the shift's.
class _TimingRow extends StatelessWidget {
  const _TimingRow({
    required this.label,
    required this.value,
    required this.before,
    required this.after,
  });

  final String label;
  final String value;
  final Widget before;
  final Widget after;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
          ),
        ),
        before,
        SizedBox(
          width: 76,
          child: Text(
            value,
            textAlign: TextAlign.center,
            maxLines: 1,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        after,
      ],
    );
  }
}

/// How wide and tall a button on this panel is: the television's minimum
/// target where a remote has to hit it, and a pointer-sized circle
/// otherwise.
double _buttonSize(BuildContext context) =>
    DeviceScope.isTv(context) ? TvDensity.minTarget : 40.0;

/// The space a button would have taken. Nothing is drawn in it and
/// nothing takes focus, so the remote walks straight past.
class _ButtonGap extends StatelessWidget {
  const _ButtonGap();

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: _buttonSize(context));
}

/// A round icon button on the panel: it fires once on press and then
/// keeps firing while it is held down, by pointer or by the remote's
/// select key.
///
/// Twenty presses for a two-second offset is not an adjustment, it is a
/// chore, so holding is the way a large shift gets made. The repeat is
/// this widget's own timer rather than the key's auto-repeat, so it runs
/// at the same rate on a mouse, a touch screen and a D-pad, and it stops
/// on a release, a cancel and a lost focus alike -- a timer left running
/// after the finger has gone would walk the value off on its own.
///
/// Each fire carries how many went before it in this hold, which is
/// what lets a caller step further the longer the button is held
/// ([SubtitleTimingOverlay.shiftStrideAt]). The count is the button's
/// because the hold is: a release, a cancel or a lost focus ends it,
/// and the next press starts again at nothing.
class _PanelButton extends StatefulWidget {
  const _PanelButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPress,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;

  /// The press itself, and every repeat while the button is held, given
  /// how many fires have gone before it -- 0 for the press.
  final ValueChanged<int> onPress;

  final FocusNode? focusNode;

  @override
  State<_PanelButton> createState() => _PanelButtonState();
}

class _PanelButtonState extends State<_PanelButton> {
  Timer? _hold;
  Timer? _repeat;

  /// An activate key went down on this button and has not come up yet:
  /// without it a release belonging to whatever had focus before would
  /// stop a repeat this button never started.
  bool _keyDown = false;
  bool _focused = false;

  /// How many times this hold has fired so far, and what the caller
  /// counts its strides in. Reset by [_start], so a tap is always the
  /// first stride.
  int _fires = 0;

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _start() {
    _stop();
    _fires = 0;
    _fire();
    _hold = Timer(SubtitleTimingOverlay.holdDelay, () {
      _hold = null;
      _repeat = Timer.periodic(
        SubtitleTimingOverlay.repeatInterval,
        (_) => _fire(),
      );
    });
  }

  void _fire() => widget.onPress(_fires++);

  void _stop() {
    _hold?.cancel();
    _hold = null;
    _repeat?.cancel();
    _repeat = null;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!RemotePress.activateKeys.contains(event.logicalKey)) {
      // Everything else is the screen's: the direction keys walk the
      // panel and Back closes it.
      return KeyEventResult.ignored;
    }
    switch (event) {
      case KeyDownEvent():
        _keyDown = true;
        _start();
        return KeyEventResult.handled;
      case KeyRepeatEvent():
        // The key's own repeat is ignored on purpose: [_start] has a
        // timer of its own, so the rate is ours and not the platform's.
        return _keyDown ? KeyEventResult.handled : KeyEventResult.ignored;
      case KeyUpEvent():
        // Answered whatever the button has become in the meantime: a
        // release dropped because the button stopped accepting presses
        // is the one event that stops [_repeat], and without it the
        // timer fires for the life of the panel.
        if (!_keyDown) return KeyEventResult.ignored;
        _keyDown = false;
        _stop();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onFocusChange(bool focused) {
    if (!focused) {
      _keyDown = false;
      _stop();
    }
    setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = _buttonSize(context);
    // The [Tooltip] is outside the [Focus] rather than inside it so that
    // what the remote is sitting on can be read off the focused node: it
    // names the button, and there is no other text on one.
    return Tooltip(
      message: widget.tooltip,
      // Focusable even at the end of its range: a button that gave the
      // remote up as it went dead would drop focus out of the panel
      // altogether, and there is nowhere in it for the ring to land next.
      child: Focus(
        focusNode: widget.focusNode,
        onKeyEvent: _onKeyEvent,
        onFocusChange: _onFocusChange,
        child: Semantics(
          button: true,
          label: widget.tooltip,
          // A [Listener] rather than a [GestureDetector]: a repeat has to
          // begin the moment the button is touched, and a tap recognizer
          // holds its `onTapDown` back until it has won the arena. There
          // is nothing here to compete with it anyway -- the panel is
          // opaque, so the video's own tap and double-tap never see the
          // pointer.
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) {
              widget.focusNode?.requestFocus();
              _start();
            },
            onPointerUp: (_) => _stop(),
            onPointerCancel: (_) => _stop(),
            child: SizedBox(
              width: size,
              height: size,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.12),
                  border: Border.all(
                    color: _focused
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Icon(widget.icon, size: 20, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
