import 'package:flutter/widgets.dart';

import 'faces.dart';
import 'faces_sync.dart';
import 'prefs_client.dart';

/// Hands down what keeps the device's copies in step with the account on
/// xtremio-xervice. One per app, built in `XtremioApp`; a widget test that
/// mounts none gets faces that stay on the device, which is exactly what a
/// signed-out viewer gets too.
class XerviceScope extends InheritedWidget {
  const XerviceScope({super.key, required this.faces, required super.child});

  final FacesSync faces;

  static XerviceScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<XerviceScope>();

  @override
  bool updateShouldNotify(XerviceScope oldWidget) => faces != oldWidget.faces;
}

/// Marks [id] with [face] (null takes the mark off): through the account's
/// sync where the app has one, else on this device alone.
Future<void> markFace(
  BuildContext context,
  AppPrefs prefs,
  String id,
  Face? face,
) {
  final sync = XerviceScope.maybeOf(context)?.faces;
  if (sync != null && identical(sync.prefs, prefs)) {
    return sync.setFace(id, face);
  }
  return prefs.setFaces(prefs.faces.marking(id, face, DateTime.now()));
}
