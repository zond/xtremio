import 'dart:async';

import 'package:xtremio/shell/deep_link.dart';

/// Hand-fed [DeepLinkSource] for widget tests: no platform channel, links
/// pushed in with [send].
class FakeDeepLinks implements DeepLinkSource {
  FakeDeepLinks({this.initial});

  /// The link the app is "launched with".
  final String? initial;

  final StreamController<String> _links = StreamController<String>.broadcast();

  /// Whether the app is still subscribed (false once it has disposed).
  bool get isListenedTo => _links.hasListener;

  /// Delivers [link] as if the platform had just handed it over.
  void send(String link) => _links.add(link);

  /// Delivers an error on the link stream, as an unimplemented platform
  /// channel does.
  void fail(Object error) => _links.addError(error);

  @override
  Future<String?> initialLink() async => initial;

  @override
  Stream<String> links() => _links.stream;
}
