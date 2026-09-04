import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shell/device_profile.dart';
import '../../shell/tv_density.dart';
import '../../widgets/remote_press.dart';
import 'subtitle_groups.dart';

/// What a viewer has asked of the subtitles' timing by hand, counted in
/// presses rather than in seconds and multipliers.
///
/// Two controls, because there are two ways a file can be out and only
/// one of them is computable. A **shift** answers a subtitle cut for a
/// release that starts somewhere else -- a distributor logo this video
/// does not have -- which no declared frame rate says anything about. A
/// **stretch** answers a rate that drifts, and exists on top of
/// [subtitleSpeed]'s automatic correction because an addon's `fpsMilli`
/// is a claim and a claim can be wrong: it may have declared nothing, or
/// declared the wrong thing.
///
/// Steps are integers so that ten presses back and forth land exactly
/// where they started; a double accumulated a tenth at a time does not.
@immutable
final class SubtitleTiming {
  const SubtitleTiming({
    this.automaticSpeed = 1,
    this.shiftSteps = 0,
    this.speedSteps = 0,
  });

  /// The multiplier [subtitleSpeed] computed for what is on screen, and
  /// `1.0` wherever it found nothing to correct.
  ///
  /// The stretch is taken *from* here rather than from 1.0, which is what
  /// makes one press the whole of "that correction was wrong": a file
  /// re-timed to 1.0427 goes back to its own timing in a single press
  /// down, and a file nothing corrected picks the PAL correction up in a
  /// single press up.
  final double automaticSpeed;

  /// Presses of the shift control, positive being later.
  final int shiftSteps;

  /// Presses of the speed control, positive multiplying by [speedStep].
  final int speedSteps;

  /// One press of the shift control. A tenth of a second is about the
  /// smallest offset that is visible against speech and small enough that
  /// holding the key is how a two-second correction gets made.
  static const double shiftStep = 0.1;

  /// One press of the speed control: the PAL ratio, 25/23.976 = 1.042709.
  ///
  /// The whole correction in one press, not a nudge towards it, because
  /// PAL against NTSC film is the mismatch this ever has to fix by hand.
  /// The press the other way divides by it, and getting those two round
  /// the wrong way does not half-fix the drift -- it doubles it.
  static const double speedStep = 25 / 23.976;

  /// The offset for libmpv's `sub-delay`, in seconds. Positive delays the
  /// lines, which is mpv's own sign.
  double get delay => shiftSteps * shiftStep;

  /// The multiplier for libmpv's `sub-speed`.
  double get speed => _speedAfter(speedSteps);

  /// The viewer has touched something, so there is a correction of theirs
  /// to undo. Reset is offered for exactly this.
  bool get adjusted => shiftSteps != 0 || speedSteps != 0;

  /// The offset as the overlay shows it: signed, because which way it has
  /// gone is the whole of what a viewer is tracking between presses.
  String get shiftText =>
      '${shiftSteps > 0 ? '+' : ''}${delay.toStringAsFixed(1)} s';

  /// The multiplier as the overlay shows it. Three decimals separates one
  /// PAL step from none and from two.
  String get speedText => '${speed.toStringAsFixed(3)}×';

  /// [steps] more presses of the shift control.
  SubtitleTiming shiftedBy(int steps) => SubtitleTiming(
    automaticSpeed: automaticSpeed,
    shiftSteps: shiftSteps + steps,
    speedSteps: speedSteps,
  );

  /// [steps] more presses of the speed control, or this timing unchanged
  /// when that would leave the `<0.1-10.0>` libmpv's `sub-speed` accepts.
  ///
  /// A refused write is silent (media_kit discards the return code), so
  /// what a press outside the range would really do is leave the previous
  /// multiplier running while the overlay claims a new one. Nothing is
  /// better than that, and the button that would do it is drawn disabled.
  SubtitleTiming stretchedBy(int steps) => canStretchBy(steps)
      ? SubtitleTiming(
          automaticSpeed: automaticSpeed,
          shiftSteps: shiftSteps,
          speedSteps: speedSteps + steps,
        )
      : this;

  /// Whether [stretchedBy] would move at all.
  bool canStretchBy(int steps) {
    final next = _speedAfter(speedSteps + steps);
    return next >= minSubtitleSpeed && next <= maxSubtitleSpeed;
  }

  /// Back to what the automatic path decided, which is what "undo what I
  /// did" means here -- not back to 1.0 and 0.0. A file the addons said
  /// was 25 fps against a 23.976 fps video is still that file after a
  /// reset, and resetting it to 1.0 would hand the viewer back the drift
  /// they never asked about.
  SubtitleTiming get automatic =>
      SubtitleTiming(automaticSpeed: automaticSpeed);

  double _speedAfter(int steps) =>
      automaticSpeed * math.pow(speedStep, steps).toDouble();

  @override
  bool operator ==(Object other) =>
      other is SubtitleTiming &&
      other.automaticSpeed == automaticSpeed &&
      other.shiftSteps == shiftSteps &&
      other.speedSteps == speedSteps;

  @override
  int get hashCode => Object.hash(automaticSpeed, shiftSteps, speedSteps);

  @override
  String toString() =>
      'SubtitleTiming(auto: $automaticSpeed, shift: $shiftSteps, '
      'speed: $speedSteps)';
}

/// The panel that drives a [SubtitleTiming]: two steppers and a reset.
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
    required this.onStretch,
    required this.onReset,
    required this.onClose,
    this.firstFocusNode,
  });

  final SubtitleTiming timing;

  /// One press of the shift control: `-1` earlier, `1` later.
  final ValueChanged<int> onShift;

  /// One press of the speed control: `-1` divides by the PAL ratio, `1`
  /// multiplies by it.
  final ValueChanged<int> onStretch;

  /// Back to [SubtitleTiming.automatic].
  final VoidCallback onReset;
  final VoidCallback onClose;

  /// Attached to the first button: where the remote lands when the panel
  /// opens.
  final FocusNode? firstFocusNode;

  static const String title = 'Subtitle timing';
  static const String shiftLabel = 'Shift';
  static const String speedLabel = 'Speed';
  static const String resetLabel = 'Reset';

  /// Wide enough for the widest row at the television's text scale, and
  /// fixed so that a number growing a digit does not move the buttons the
  /// remote is sitting on.
  static const double width = 300;

  /// How long a stepper has to be held before it starts repeating.
  static const Duration holdDelay = Duration(milliseconds: 400);

  /// How often it steps after that: fast enough that a two-second shift
  /// is a couple of seconds of holding, slow enough to let go on a value.
  static const Duration repeatInterval = Duration(milliseconds: 120);

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
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                _Stepper(
                  label: shiftLabel,
                  value: timing.shiftText,
                  downKey: 'subtitle-shift-earlier',
                  upKey: 'subtitle-shift-later',
                  downTooltip: 'Subtitles earlier',
                  upTooltip: 'Subtitles later',
                  onStep: onShift,
                  firstFocusNode: firstFocusNode,
                ),
                _Stepper(
                  label: speedLabel,
                  value: timing.speedText,
                  downKey: 'subtitle-speed-down',
                  upKey: 'subtitle-speed-up',
                  // mpv multiplies the event timestamps by `sub-speed`,
                  // so a larger multiplier pushes every cue later and
                  // spreads them further apart: the subtitle runs
                  // *slower* through the film, which is what a file cut
                  // for 25 fps needs against 23.976 fps footage.
                  downTooltip: 'Subtitles run faster',
                  upTooltip: 'Subtitles run slower',
                  onStep: onStretch,
                  canStepDown: timing.canStretchBy(-1),
                  canStepUp: timing.canStretchBy(1),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const ValueKey('subtitle-timing-reset'),
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

/// One labelled row: a minus, the value it is showing, and a plus.
///
/// Left and right along the row is the shape a remote expects of a pair
/// of steppers, and it is what directional traversal gives for free from
/// the geometry -- which is why the buttons are siblings in a `Row` and
/// not something drawn inside a focusable tile.
class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.downKey,
    required this.upKey,
    required this.downTooltip,
    required this.upTooltip,
    required this.onStep,
    this.canStepDown = true,
    this.canStepUp = true,
    this.firstFocusNode,
  });

  final String label;
  final String value;
  final String downKey;
  final String upKey;
  final String downTooltip;
  final String upTooltip;
  final ValueChanged<int> onStep;
  final bool canStepDown;
  final bool canStepUp;
  final FocusNode? firstFocusNode;

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
        _HoldButton(
          key: ValueKey(downKey),
          icon: Icons.remove,
          tooltip: downTooltip,
          enabled: canStepDown,
          focusNode: firstFocusNode,
          onPress: () => onStep(-1),
        ),
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
        _HoldButton(
          key: ValueKey(upKey),
          icon: Icons.add,
          tooltip: upTooltip,
          enabled: canStepUp,
          onPress: () => onStep(1),
        ),
      ],
    );
  }
}

/// A button that fires once on press and then keeps firing while it is
/// held down, by pointer or by the remote's select key.
///
/// Twenty presses for a two-second offset is not an adjustment, it is a
/// chore, so holding is the way a large correction gets made. The repeat
/// is this widget's own timer rather than the key's auto-repeat, so it
/// runs at the same rate on a mouse, a touch screen and a D-pad, and it
/// stops on a release, a cancel and a lost focus alike -- a timer left
/// running after the finger has gone would walk the value off on its own.
class _HoldButton extends StatefulWidget {
  const _HoldButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPress,
    this.enabled = true,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPress;
  final bool enabled;
  final FocusNode? focusNode;

  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> {
  Timer? _hold;
  Timer? _repeat;

  /// An activate key went down on this button and has not come up yet:
  /// without it a release belonging to whatever had focus before would
  /// stop a repeat this button never started.
  bool _keyDown = false;
  bool _focused = false;

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _start() {
    if (!widget.enabled) return;
    _stop();
    widget.onPress();
    _hold = Timer(SubtitleTimingOverlay.holdDelay, () {
      _hold = null;
      _repeat = Timer.periodic(
        SubtitleTimingOverlay.repeatInterval,
        (_) => widget.onPress(),
      );
    });
  }

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
    if (!widget.enabled) return KeyEventResult.ignored;
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
    final size = DeviceScope.isTv(context) ? TvDensity.minTarget : 40.0;
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
          enabled: widget.enabled,
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
                child: Icon(
                  widget.icon,
                  size: 20,
                  color: widget.enabled ? Colors.white : Colors.white30,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
