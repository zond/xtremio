import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

/// Opens a URL outside the app (the system browser): addon configuration
/// pages, help links. Behind an interface so widget tests can assert which
/// URL a button opens instead of launching anything.
abstract interface class ExternalLinkOpener {
  /// Hands [url] to the platform; false when nothing could open it.
  Future<bool> open(Uri url);
}

/// `url_launcher.launchUrl`, as far as this opener uses it.
typedef LaunchUrl = Future<bool> Function(
  Uri url, {
  required url_launcher.LaunchMode mode,
});

/// The real thing, over `url_launcher`. Always an external application:
/// an in-app web view would hide the address bar the user needs to trust
/// an addon's configuration page.
///
/// A launch that fails is reported as `false`, whichever way the platform
/// says so: `url_launcher_linux` never returns false but throws a
/// `PlatformException` when nothing opens the URL, and a URL the plugin
/// cannot handle is an `ArgumentError`. Either would otherwise escape past
/// the caller's "Could not open" message.
class UrlLauncherLinkOpener implements ExternalLinkOpener {
  const UrlLauncherLinkOpener({this.launch = url_launcher.launchUrl});

  /// The launcher itself; tests substitute one that throws.
  final LaunchUrl launch;

  @override
  Future<bool> open(Uri url) async {
    try {
      return await launch(
        url,
        mode: url_launcher.LaunchMode.externalApplication,
      );
    } on PlatformException {
      return false;
    } on ArgumentError {
      return false;
    }
  }
}

/// Provides the [ExternalLinkOpener] to the widget tree. Without a scope
/// the real [UrlLauncherLinkOpener] is used, so the app needs none; tests
/// wrap the widget under test in one with a fake.
class ExternalLinkScope extends InheritedWidget {
  const ExternalLinkScope({
    super.key,
    required this.opener,
    required super.child,
  });

  final ExternalLinkOpener opener;

  static ExternalLinkOpener of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ExternalLinkScope>()?.opener ??
      const UrlLauncherLinkOpener();

  @override
  bool updateShouldNotify(ExternalLinkScope oldWidget) =>
      opener != oldWidget.opener;
}
