import 'package:xtremio/core/core.dart';

/// The server's stream-closing call, faked: it records the tokens it was
/// asked to close and answers how many streams that supposedly ended.
///
/// Every player test gets one through [PlayerHarness], so leaving a screen
/// never reaches FFI -- and so a test can say the player closed *its own*
/// token and nobody else's.
class FakeProxyStreams implements ProxyStreamControl {
  /// Every token closed, in order. A player that closed nothing leaves it
  /// empty, which is the assertion for a torrent: it was never proxied, so
  /// there is nothing to ask about.
  final List<String> closed = [];

  /// What [closeProxyStreams] answers -- how many live streams the server
  /// would say carried the token. One by default; zero is the ordinary
  /// answer for a player whose stream had already finished.
  int liveStreams = 1;

  @override
  int closeProxyStreams(String token) {
    closed.add(token);
    return liveStreams;
  }
}
