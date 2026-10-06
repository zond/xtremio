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
/// **What is left of a held key after the long press is nobody's.** The
/// long press usually opens something -- a sheet, a dialog -- that takes
/// focus while the key is still down, and Android goes on sending the
/// key's repeats every 50 ms until it comes up. Flutter's default
/// shortcuts activate on a repeat as well as on a press, so the first
/// repeat pressed whatever the new sheet had focused (its Cancel, its
/// first entry) and the next ones the tile under it again. So once the
/// long press has fired, every remaining event of that key -- repeats and
/// the release -- is swallowed before the focus tree sees it
/// ([_SpentHold]), whoever has focus by then.
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
    // A remote whose centre key is `KEYCODE_NUMPAD_ENTER`: Flutter's own
    // shortcuts activate on it, so it must be taken here or a hold on it
    // is a stream of taps.
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  @override
  State<RemotePress> createState() => _RemotePressState();
}

/// Sent up the tree when select taps a [RemotePress], after its `onTap`
/// has run. The press itself stops at the card, so this is how an ancestor
/// learns of it -- a [TvLadderRow] that moves the remote on after a select
/// (`advanceOnSelect`). Not sent for a long press, nor for a touch.
class RemotePressed extends Notification {
  const RemotePressed();
}

class _RemotePressState extends State<RemotePress> {
  /// Running while an activate key is held and has not become a long press.
  Timer? _hold;

  /// An activate key went down here and has not come up yet.
  bool _down = false;

  /// The current hold already fired [RemotePress.onLongPress].
  bool _longPressed = false;

  /// The activate key that is down here.
  LogicalKeyboardKey? _heldKey;

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
    _heldKey = null;
  }

  void _onHoldElapsed() {
    _hold = null;
    final onLongPress = widget.onLongPress;
    if (onLongPress == null) return;
    _longPressed = true;
    final key = _heldKey;
    if (key != null) _SpentHold.swallow(key);
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
        _heldKey = key;
        _hold = Timer(RemotePress.holdDuration, _onHoldElapsed);
        return KeyEventResult.handled;
      case KeyRepeatEvent():
        return _down ? KeyEventResult.handled : KeyEventResult.ignored;
      case KeyUpEvent():
        if (!_down) return KeyEventResult.ignored;
        final tap = !_longPressed;
        _reset();
        if (tap) {
          widget.onTap?.call();
          const RemotePressed().dispatch(context);
        }
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

/// The rest of a held key whose long press has fired: its repeats and its
/// release, taken before the focus tree sees them (see [RemotePress]).
///
/// One key at a time, app-wide, as a remote has one centre key. An early
/// key handler on the [FocusManager] rather than a [Focus] anywhere in the
/// tree, because what the long press opened is a new route, above every
/// widget this one could put round itself.
abstract final class _SpentHold {
  static LogicalKeyboardKey? _key;

  static void swallow(LogicalKeyboardKey key) {
    if (_key == null) FocusManager.instance.addEarlyKeyEventHandler(_handle);
    _key = key;
  }

  static void _release() {
    _key = null;
    FocusManager.instance.removeEarlyKeyEventHandler(_handle);
  }

  static KeyEventResult _handle(KeyEvent event) {
    if (event.logicalKey != _key) return KeyEventResult.ignored;
    switch (event) {
      case KeyRepeatEvent():
        return KeyEventResult.handled;
      case KeyUpEvent():
        _release();
        return KeyEventResult.handled;
      case KeyDownEvent():
        // A press of its own: the release this was waiting for never came
        // (the app went to the background mid-hold, say). It is not the
        // spent hold's, so it goes through.
        _release();
        return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }
}
