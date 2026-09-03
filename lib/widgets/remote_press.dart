import 'dart:async';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The remote's select and menu keys on a focusable [child], for a TV.
///
/// Android activates a control when the centre key is *released*, and a
/// centre key held down is a long press. Flutter's default shortcut for
/// `select` fires `ActivateIntent` on the way down instead, and again on
/// every repeat while the key is held, so holding the key on a poster would
/// open its details over and over and nothing would be left to mean "more
/// options". This widget takes select (and the other activate keys) on the
/// way down and decides on the way up: released within [holdDuration] it is
/// [onTap]; held longer, [onLongPress] fires once, when the time is up, and
/// the release does nothing. The remote's menu key
/// ([LogicalKeyboardKey.contextMenu], Android's `KEYCODE_MENU`) is
/// [onLongPress] too, straight away. Every other key passes through.
///
/// A hold with no [onLongPress] still taps on release, as Android does.
/// The child keeps its own tap handlers for pointers (a touch remote, a
/// mouse); this widget only listens to keys, and only for the key events
/// of whichever descendant holds focus. Off a television nothing needs it:
/// the screens wrap their tiles only when [DeviceScope.isTv].
class RemotePress extends StatefulWidget {
  const RemotePress({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// How long select must stay down to be a long press: Android's own
  /// long-press timeout, so the remote feels like every other TV app.
  static const Duration holdDuration = kLongPressTimeout;

  /// The keys that activate the focused control, per Flutter's defaults for
  /// Android: the D-pad's centre, Enter and a gamepad's A.
  static final Set<LogicalKeyboardKey> activateKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.gameButtonA,
  };

  @override
  State<RemotePress> createState() => _RemotePressState();
}

class _RemotePressState extends State<RemotePress> {
  /// Running while an activate key is held and has not become a long press.
  Timer? _hold;

  /// An activate key went down here and has not come up yet.
  bool _down = false;

  /// The current hold already fired [RemotePress.onLongPress].
  bool _longPressed = false;

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  void _reset() {
    _hold?.cancel();
    _hold = null;
    _down = false;
    _longPressed = false;
  }

  void _onHoldElapsed() {
    _hold = null;
    final onLongPress = widget.onLongPress;
    if (onLongPress == null) return;
    _longPressed = true;
    onLongPress();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.contextMenu) {
      final onLongPress = widget.onLongPress;
      if (onLongPress == null) return KeyEventResult.ignored;
      if (event is KeyDownEvent) onLongPress();
      return KeyEventResult.handled;
    }
    if (!RemotePress.activateKeys.contains(key)) return KeyEventResult.ignored;
    if (widget.onTap == null && widget.onLongPress == null) {
      return KeyEventResult.ignored;
    }
    switch (event) {
      case KeyDownEvent():
        _reset();
        _down = true;
        _hold = Timer(RemotePress.holdDuration, _onHoldElapsed);
        return KeyEventResult.handled;
      case KeyRepeatEvent():
        return _down ? KeyEventResult.handled : KeyEventResult.ignored;
      case KeyUpEvent():
        if (!_down) return KeyEventResult.ignored;
        final tap = !_longPressed;
        _reset();
        if (tap) widget.onTap?.call();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Focus left the child (a long press opened something over it, say)
  /// before the key came up: that release belongs to whatever has focus now.
  void _onFocusChange(bool hasFocus) {
    if (!hasFocus) _reset();
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    includeSemantics: false,
    onKeyEvent: _onKeyEvent,
    onFocusChange: _onFocusChange,
    child: widget.child,
  );
}
