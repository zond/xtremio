import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the screen on while the film plays, whichever output shows it.
///
/// It is the player's one owner of the screen's keep-on flag. It wraps both
/// outputs, because the surface (`VideoOutput.surface`) builds no media_kit
/// `Video`, and `Video`'s own hold is off (`wakelock: false`) so that nothing
/// else turns the flag on or off.
///
/// It follows [playing] (mpv's `pause`, as media_kit reports it): on while
/// the film plays, off when it is paused, and off when the widget goes.
class ScreenAwakeWhilePlaying extends StatefulWidget {
  const ScreenAwakeWhilePlaying({
    super.key,
    required this.playing,
    required this.initial,
    required this.child,
    this.setAwake = _wakelock,
  });

  /// Whether the film plays, from `Player.stream.playing`.
  final Stream<bool> playing;

  /// Whether it plays when the widget is built, before [playing] says more.
  final bool initial;

  final Widget child;

  /// Turns the keep-on flag on or off. A test passes a recorder.
  final Future<void> Function(bool awake) setAwake;

  static Future<void> _wakelock(bool awake) =>
      WakelockPlus.toggle(enable: awake);

  @override
  State<ScreenAwakeWhilePlaying> createState() =>
      _ScreenAwakeWhilePlayingState();
}

class _ScreenAwakeWhilePlayingState extends State<ScreenAwakeWhilePlaying> {
  StreamSubscription<bool>? _subscription;
  bool? _awake;

  @override
  void initState() {
    super.initState();
    _set(widget.initial);
    _subscription = widget.playing.listen(_set);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _set(false);
    super.dispose();
  }

  void _set(bool awake) {
    if (_awake == awake) return;
    _awake = awake;
    widget.setAwake(awake).ignore();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
