import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Whether the player's controls are up, and the timer that fades them.
///
/// **What may hold them up is asked, never told** ([canFade]). The screen
/// answers from what is on it now: a pause, a menu, a scrub, a wait, the
/// up-next card. Nothing takes a hold here and nothing has to release one,
/// so no path can leave the controls held up by forgetting to. That is the
/// fault `rebuilt` exists for: a bar brought up while something held it had
/// no timer when the hold went.
///
/// This keeps the rest: the flag, the timer, and arming the timer the moment
/// the controls may fade again. It notifies when [visible] changes.
class ControlsVisibility extends ChangeNotifier {
  ControlsVisibility({
    required this.timeout,
    required this.canFade,
    this.onHidden,
    void Function(VoidCallback)? afterFrame,
  }) : _afterFrame = afterFrame ?? _nextFrame;

  /// How long the controls stay up after the last thing that showed them.
  final Duration timeout;

  /// Whether nothing on screen holds the controls up now.
  final bool Function() canFade;

  /// Runs after the controls were put away, by the timer or by [hide]. The
  /// screen hands the remote back to the video there.
  final VoidCallback? onHidden;

  final void Function(VoidCallback) _afterFrame;

  static void _nextFrame(VoidCallback callback) =>
      SchedulerBinding.instance.addPostFrameCallback((_) => callback());

  bool _visible = true;
  Timer? _timer;
  bool _couldFade = false;
  bool _stopped = false;

  /// Whether the controls are up by this class's account. They are also up
  /// whatever this says while something holds them ([shown]).
  bool get visible => _visible;

  /// Whether the controls are on screen: up, or held up.
  bool get shown => _visible || !canFade();

  /// Brings the controls up, and starts their fade over.
  void show() {
    if (!_visible) {
      _visible = true;
      notifyListeners();
    }
    restart();
  }

  /// Puts the controls away now, when nothing holds them up. Answers
  /// whether they went.
  bool hide() {
    _cancel();
    if (_stopped || !canFade() || !_visible) return false;
    _visible = false;
    notifyListeners();
    onHidden?.call();
    return true;
  }

  /// Starts the fade over: the controls go [timeout] from now, if they are
  /// up and nothing holds them by then.
  void restart() {
    _cancel();
    if (_stopped || !canFade() || !_visible) return;
    _timer = Timer(timeout, hide);
  }

  /// Stops the fade without putting anything away: a sheet is opening, or
  /// a scrub began. Whatever ends it calls [restart] or [show].
  void pause() => _cancel();

  /// The screen rebuilt. When the controls have just become free to fade,
  /// the fade is armed after this frame.
  ///
  /// Whatever held them up can go in many ways, and each one is a rebuild.
  /// So the change is read here, once, rather than at each of them.
  void rebuilt() {
    final can = canFade();
    final became = can && !_couldFade;
    _couldFade = can;
    if (!became) return;
    _afterFrame(() {
      if (!_stopped) restart();
    });
  }

  /// Nothing fades from here on: the screen is on its way out.
  void stop() {
    _stopped = true;
    _cancel();
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
