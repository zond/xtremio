import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

/// Opens a URL outside the app (the system browser): addon configuration
/// pages, help links. Behind an interface so widget tests can assert which
/// URL a button opens instead of launching anything.
abstract interface class ExternalLinkOpener {
  /// Hands [url] to the platform; false when nothing could open it.
  Future<bool> open(Uri url);
}

/// The real thing, over `url_launcher`. Always an external application:
/// an in-app web view would hide the address bar the user needs to trust
/// an addon's configuration page.
class UrlLauncherLinkOpener implements ExternalLinkOpener {
  const UrlLauncherLinkOpener();

  @override
  Future<bool> open(Uri url) => url_launcher.launchUrl(
    url,
    mode: url_launcher.LaunchMode.externalApplication,
  );
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
