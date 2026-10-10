import 'package:flutter/widgets.dart';

/// A rung of a screen's Back ladder: while [active], Back calls [onBack]
/// and goes no further; while not, the press passes it by.
///
/// A [PopScope] on its own cannot say that. A route calls every `PopScope` it
/// holds on a refused pop, in no order the screen controls. The shell has a
/// ladder of its own (`RootShell`), so it would take its step on the same
/// press that closed a menu inside a tab. Under a [BackRungs] the rung also
/// says that it is up, and the shell asks before it steps.
///
/// What is asked is [active] as the rung was last built. A rung puts itself
/// away with a `setState`, which takes effect a frame after the press. So the
/// answer is the same whether the shell asks before or after the rung's own
/// [onBack] ran.
///
/// Outside a [BackRungs] it is a plain [PopScope].
class BackRung extends StatefulWidget {
  const BackRung({
    super.key,
    required this.active,
    required this.onBack,
    required this.child,
  });

  /// Whether the rung has something to put away.
  final bool active;

  /// Puts it away; called only while [active].
  final VoidCallback onBack;

  final Widget child;

  @override
  State<BackRung> createState() => _BackRungState();
}

class _BackRungState extends State<BackRung> {
  BackRungs? _rungs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final rungs = context
        .getInheritedWidgetOfExactType<_BackRungsScope>()
        ?.rungs;
    if (rungs == _rungs) return;
    _rungs?._up.remove(this);
    _rungs = rungs?.._up.add(this);
  }

  @override
  void dispose() {
    _rungs?._up.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !widget.active,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && widget.active) widget.onBack();
    },
    child: widget.child,
  );
}

/// The [BackRung]s below a ladder's owner, which asks [anyActive] before it
/// takes a step of its own; see [BackRung].
class BackRungs {
  final Set<_BackRungState> _up = {};

  /// Whether a rung below has something to put away.
  bool get anyActive => _up.any((rung) => rung.mounted && rung.widget.active);

  /// Puts [rungs] above [child].
  static Widget scope({required BackRungs rungs, required Widget child}) =>
      _BackRungsScope(rungs: rungs, child: child);
}

class _BackRungsScope extends InheritedWidget {
  const _BackRungsScope({required this.rungs, required super.child});

  final BackRungs rungs;

  @override
  bool updateShouldNotify(_BackRungsScope oldWidget) =>
      rungs != oldWidget.rungs;
}
