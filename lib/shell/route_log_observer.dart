import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Debug-only diagnostics: logs every route push/pop/remove/replace so a log
/// that ends in an unexpected exit shows what navigation preceded it.
class RouteLogObserver extends NavigatorObserver {
  static String _name(Route<dynamic>? route) => route == null
      ? '<none>'
      : (route.settings.name ?? '${route.runtimeType}');

  void _log(String event, Route<dynamic>? route, Route<dynamic>? other) {
    if (!kDebugMode) return;
    debugPrint('route $event: ${_name(route)} (previous: ${_name(other)})');
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _log('push', route, previousRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _log('pop', route, previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _log('remove', route, previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _log('replace', newRoute, oldRoute);
}
