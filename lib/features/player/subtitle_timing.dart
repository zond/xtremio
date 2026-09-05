import 'dart:async';

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
/// **stretch** answers a rate that drifts.
///
/// Nothing else writes either property, so what is in this is the whole
/// of what mpv is playing: a declared frame rate is a claim about the
/// release an upload was made for, and the same claim covers files that
/// keep time and files that do not, so acting on it fixes one and breaks
/// the other in equal measure. The viewer watching the drift is the only
/// one who can tell those apart.
///
/// The shift is counted in integer presses so that ten forward and ten
/// back land exactly where they started; a double accumulated a tenth at
/// a time does not. The toggle is not counted at all -- it is one
/// direction or none.
///
/// Both also have a measured form ([calibratedSpeed], [calibratedDelay]),
/// which is what the viewer marking the picture right solves for
/// (`SubtitleCalibration`). A measurement wins over the toggle and the
/// presses count on top of the measured offset, so pressing after a
/// calibration still comes back to it exactly.
@immutable
final class SubtitleTiming {
  const SubtitleTiming({
    this.shiftSteps = 0,
    this.speedDirection,
    this.calibratedSpeed,
    this.calibratedDelay,
  });

  /// Presses of the shift control, positive being later.
  final int shiftSteps;

  /// Which way the speed control has been pressed, and null for the
  /// file's own timing.
  ///
  /// A direction rather than a count, because there is nothing to count:
  /// the only mismatch a subtitle can have with a video is PAL against
  /// film, so the correction is either in force or it is not. Holding it
  /// this way is what makes a second press land on exactly 1.0 rather
  /// than on the ratio squared, which is a place no viewer means to
  /// arrive.
  final SubtitleSpeedDirection? speedDirection;

  /// The ratio a calibration solved for, and null when none has.
  ///
  /// It wins over [speedDirection], which is a guess at the same
  /// quantity from a declared frame rate: two marks far enough apart
  /// measure the drift on this pair of files instead of naming the
  /// family it probably came from. The owner's own Swedish file wants
  /// 1.0440 where the PAL constant is 1.0427, which is three seconds
  /// across an episode that no toggle reaches.
  final double? calibratedSpeed;

  /// The offset a calibration solved for, in seconds, and null when none
  /// has.
  ///
  /// The presses are counted on top of it rather than folded into it, so
  /// a nudge after a calibration still comes back to the calibrated
  /// value exactly.
  final double? calibratedDelay;

  /// One press of the shift control. A tenth of a second is about the
  /// smallest offset that is visible against speech and small enough that
  /// holding the key is how a two-second correction gets made.
  static const double shiftStep = 0.1;

  /// What the speed control is worth: the PAL ratio, 25/23.976 =
  /// 1.042709.
  ///
  /// The whole correction in one press, not a nudge towards it, because
  /// PAL against film is the only mismatch there is to fix -- every other
  /// pair of rates is the same seconds. [SubtitleSpeedDirection.compress]
  /// divides by it, and getting those two round the wrong way does not
  /// half-fix the drift, it doubles it.
  static const double speedStep = 25 / 23.976;

  /// The offset for libmpv's `sub-delay`, in seconds. Positive delays the
  /// lines, which is mpv's own sign.
  double get delay => (calibratedDelay ?? 0) + shiftSteps * shiftStep;

  /// The multiplier for libmpv's `sub-speed`: three values and no
  /// others, all of them well inside the `<0.1-10.0>` mpv accepts.
  double get speed =>
      calibratedSpeed ??
      switch (speedDirection) {
        null => 1,
        SubtitleSpeedDirection.stretch => speedStep,
        SubtitleSpeedDirection.compress => 1 / speedStep,
      };

  /// The viewer has touched something, so there is a correction of theirs
  /// to undo. Reset is offered for exactly this.
  bool get adjusted =>
      shiftSteps != 0 ||
      speedDirection != null ||
      calibratedSpeed != null ||
      calibratedDelay != null;

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
    speedDirection: speedDirection,
    calibratedSpeed: calibratedSpeed,
    calibratedDelay: calibratedDelay,
  );

  /// [direction] applied, or taken off again when it is already what is
  /// in force: the control is a toggle, so a second press is how a
  /// viewer who judged wrong gets back to exactly 1.0.
  /// A calibrated ratio is dropped by the press: it is the same quantity
  /// measured rather than judged, and leaving it in force would make the
  /// button do nothing at all.
  SubtitleTiming toggledSpeed(SubtitleSpeedDirection direction) =>
      SubtitleTiming(
        shiftSteps: shiftSteps,
        speedDirection: speedDirection == direction ? null : direction,
        calibratedDelay: calibratedDelay,
      );

  @override
  bool operator ==(Object other) =>
      other is SubtitleTiming &&
      other.shiftSteps == shiftSteps &&
      other.speedDirection == speedDirection &&
      other.calibratedSpeed == calibratedSpeed &&
      other.calibratedDelay == calibratedDelay;

  @override
  int get hashCode =>
      Object.hash(shiftSteps, speedDirection, calibratedSpeed, calibratedDelay);

  @override
  String toString() =>
      'SubtitleTiming(delay: $delay, speed: $speed, '
      'shift: $shiftSteps, direction: ${speedDirection?.name})';
}

/// The panel that drives a [SubtitleTiming]: a stepper, a toggle and a
/// reset.
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
    required this.videoDirection,
    required this.onShift,
    required this.onSpeed,
    required this.onReset,
    required this.onClose,
    this.firstFocusNode,
  });

  final SubtitleTiming timing;

  /// Which way this video's subtitles have to be pressed
  /// ([subtitleSpeedDirection]), and null when the container declared no
  /// rate we can place in either family.
  ///
  /// The video decides the direction, so the speed control is one button
  /// and pressing it twice comes back to 1.0. Both buttons are offered
  /// for that null: a stream whose rate mpv never reports would
  /// otherwise be unfixable, and offering the pair is the one honest
  /// answer to knowing nothing. The other case is [_speedButton]'s: a
  /// correction already in force is never left without the button that
  /// takes it off.
  final SubtitleSpeedDirection? videoDirection;

  /// One press of the shift control: `-1` earlier, `1` later.
  final ValueChanged<int> onShift;

  /// A press on the speed control, which is a toggle: pressing the
  /// direction already in force takes it off again.
  final ValueChanged<SubtitleSpeedDirection> onSpeed;

  /// Back to untouched: speed 1.0, shift 0.0. With nothing else writing
  /// either property, "undo what I did" and "back to untouched" are the
  /// same thing.
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

  /// How long the shift stepper has to be held before it starts
  /// repeating.
  static const Duration holdDelay = Duration(milliseconds: 400);

  /// How often it steps after that: fast enough that a two-second shift
  /// is a couple of seconds of holding, slow enough to let go on a value.
  static const Duration repeatInterval = Duration(milliseconds: 120);

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

  /// The speed button for [direction], or the space it would have taken
  /// when the video has already ruled it out and nothing is in force in
  /// it.
  ///
  /// mpv multiplies the event timestamps by `sub-speed`, so the larger
  /// multiplier pushes every cue later and spreads them further apart:
  /// the subtitle runs *slower* through the film, which is what a file
  /// cut for 25 fps needs against 23.976 fps footage.
  ///
  /// A correction that is in force keeps its button whatever the video
  /// says, because the toggle is the only way back to exactly 1.0 and a
  /// gap cannot be pressed: the button that *is* drawn would replace the
  /// direction with its reciprocal and never reach 1.0 at all. That is
  /// reachable without anything remembering anything -- [videoDirection]
  /// follows `container-fps`, which mpv works out when it has probed the
  /// container and not before, so a press made while it still says
  /// nothing can land in the direction the answer then rules out.
  Widget _speedButton(SubtitleSpeedDirection direction) {
    final inForce = timing.speedDirection == direction;
    if (!inForce && videoDirection != null && videoDirection != direction) {
      return const _ButtonGap();
    }
    final stretch = direction == SubtitleSpeedDirection.stretch;
    return _PanelButton(
      key: ValueKey(
        stretch ? 'subtitle-speed-stretch' : 'subtitle-speed-compress',
      ),
      icon: stretch ? Icons.unfold_more : Icons.unfold_less,
      tooltip: stretch ? 'Subtitles run slower' : 'Subtitles run faster',
      toggled: timing.speedDirection == direction,
      onPress: () => onSpeed(direction),
    );
  }

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
                _TimingRow(
                  label: shiftLabel,
                  value: timing.shiftText,
                  before: _PanelButton(
                    key: const ValueKey('subtitle-shift-earlier'),
                    icon: Icons.remove,
                    tooltip: 'Subtitles earlier',
                    repeats: true,
                    focusNode: firstFocusNode,
                    onPress: () => onShift(-1),
                  ),
                  after: _PanelButton(
                    key: const ValueKey('subtitle-shift-later'),
                    icon: Icons.add,
                    tooltip: 'Subtitles later',
                    repeats: true,
                    onPress: () => onShift(1),
                  ),
                ),
                _TimingRow(
                  label: speedLabel,
                  value: timing.speedText,
                  // The direction the video does *not* call for leaves a
                  // gap the width of a button, so the value and the
                  // button that is there stay in the same columns as the
                  // shift row's -- and a press lands where the eye is
                  // already looking.
                  before: _speedButton(SubtitleSpeedDirection.compress),
                  after: _speedButton(SubtitleSpeedDirection.stretch),
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
/// has.
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

/// A round icon button on the panel, which when [repeats] is set fires
/// once on press and then keeps firing while it is held down, by pointer
/// or by the remote's select key.
///
/// Twenty presses for a two-second offset is not an adjustment, it is a
/// chore, so holding is the way a large shift gets made. The repeat is
/// this widget's own timer rather than the key's auto-repeat, so it runs
/// at the same rate on a mouse, a touch screen and a D-pad, and it stops
/// on a release, a cancel and a lost focus alike -- a timer left running
/// after the finger has gone would walk the value off on its own. The
/// speed control does not repeat: it is a toggle, and a toggle held down
/// would flip eight times a second.
class _PanelButton extends StatefulWidget {
  const _PanelButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPress,
    this.repeats = false,
    this.toggled,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPress;
  final bool repeats;

  /// Whether this button's own correction is in force, for a button that
  /// is a toggle; null for one that is not.
  final bool? toggled;

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

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _start() {
    _stop();
    widget.onPress();
    if (!widget.repeats) return;
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
          toggled: widget.toggled,
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
                  // A toggle that is on is filled, because the panel has
                  // to say what is in force after the OSD bar has gone
                  // and the number alone is a three-decimal difference.
                  color: widget.toggled ?? false
                      ? theme.colorScheme.primary.withValues(alpha: 0.45)
                      : Colors.white.withValues(alpha: 0.12),
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
