import 'package:flutter/material.dart';

import '../shell/device_profile.dart';

/// The D-pad's way out of a single-line text field on a TV.
///
/// [EditableText] claims every arrow key while it has focus: its selection
/// actions are enabled whenever the selection is valid, so an arrow at the
/// edge of the text does nothing and the remote is stuck in the field. Wrap
/// the [TextField] (the one editing [controller]) in this: on a TV an
/// [Actions] above the field overrides the field's own actions
/// ([EditableText] makes them overridable) so that a horizontal step past
/// the start or end of the text, or any vertical step (one line has no line
/// above or below), moves focus in that direction instead. Any other step
/// is the field's own caret movement. Off a TV it is just [child].
class RemoteFieldExit extends StatelessWidget {
  const RemoteFieldExit({
    super.key,
    required this.controller,
    required this.child,
  });

  final TextEditingController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!DeviceScope.isTv(context)) return child;
    return Actions(
      actions: <Type, Action<Intent>>{
        ExtendSelectionByCharacterIntent:
            _LeaveFieldAction<ExtendSelectionByCharacterIntent>(
              controller: controller,
              axis: Axis.horizontal,
            ),
        ExtendSelectionVerticallyToAdjacentLineIntent:
            _LeaveFieldAction<ExtendSelectionVerticallyToAdjacentLineIntent>(
              controller: controller,
              axis: Axis.vertical,
            ),
      },
      child: child,
    );
  }
}

/// See [RemoteFieldExit].
class _LeaveFieldAction<T extends DirectionalTextEditingIntent>
    extends ContextAction<T> {
  _LeaveFieldAction({required this.controller, required this.axis});

  final TextEditingController controller;
  final Axis axis;

  bool _leaves(bool forward) {
    if (axis == Axis.vertical) return true;
    final value = controller.value;
    if (!value.selection.isValid) return true;
    final offset = value.selection.extentOffset;
    return forward ? offset >= value.text.length : offset <= 0;
  }

  TraversalDirection _direction(bool forward) => switch (axis) {
    Axis.horizontal =>
      forward ? TraversalDirection.right : TraversalDirection.left,
    Axis.vertical => forward ? TraversalDirection.down : TraversalDirection.up,
  };

  @override
  bool isEnabled(T intent, [BuildContext? context]) =>
      _leaves(intent.forward) ||
      (callingAction?._isEnabledWith(intent, context) ?? false);

  @override
  Object? invoke(T intent, [BuildContext? context]) {
    if (_leaves(intent.forward)) {
      primaryFocus?.focusInDirection(_direction(intent.forward));
      return null;
    }
    final calling = callingAction;
    return calling is ContextAction<T>
        ? calling.invoke(intent, context)
        : calling?.invoke(intent);
  }
}

extension on Action<Intent> {
  /// [Action.isEnabled], with the context when the action wants one.
  bool _isEnabledWith(Intent intent, BuildContext? context) {
    final action = this;
    return action is ContextAction<Intent>
        ? action.isEnabled(intent, context)
        : action.isEnabled(intent);
  }
}
