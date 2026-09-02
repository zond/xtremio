import 'package:flutter/widgets.dart';

import 'core_client.dart';

/// Makes the [CoreClient] (and what its init reported) available to the
/// widget tree. Plain InheritedWidget; no state-management dependency.
class CoreScope extends InheritedWidget {
  const CoreScope({
    super.key,
    required this.client,
    this.initInfo,
    required super.child,
  });

  final CoreClient client;
  final CoreInitInfo? initInfo;

  static CoreScope _scope(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<CoreScope>();
    assert(scope != null, 'No CoreScope above this widget');
    return scope!;
  }

  static CoreClient of(BuildContext context) => _scope(context).client;

  static CoreInitInfo? initInfoOf(BuildContext context) =>
      _scope(context).initInfo;

  @override
  bool updateShouldNotify(CoreScope oldWidget) =>
      client != oldWidget.client || initInfo != oldWidget.initInfo;
}
