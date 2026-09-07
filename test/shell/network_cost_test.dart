import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/network_cost.dart';

/// What the connection costs, and what happens when nobody can say.
///
/// The readings drive whether the embedded server may keep sharing between
/// sessions, so the direction every unclear case falls in is the whole
/// point: a link nobody vouched for is billed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Answers the `xtremio/network` event channel with [readings], then
  /// closes it, as `MainActivity` does while Dart is subscribed. A null
  /// list leaves the channel unanswered, as on a platform without the
  /// Kotlin side.
  void mockNetworkChannel(List<Object?>? readings) {
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler(
      ChannelNetworkCost.costChannel.name,
      readings == null
          ? null
          : (message) async {
              final call = codec.decodeMethodCall(message);
              if (call.method != 'listen') {
                return codec.encodeSuccessEnvelope(null);
              }
              for (final reading in readings) {
                await messenger.handlePlatformMessage(
                  ChannelNetworkCost.costChannel.name,
                  codec.encodeSuccessEnvelope(reading),
                  (_) {},
                );
              }
              return codec.encodeSuccessEnvelope(null);
            },
    );
    addTearDown(
      () => messenger.setMockMessageHandler(
        ChannelNetworkCost.costChannel.name,
        null,
      ),
    );
  }

  group('a reading', () {
    test('is unmetered only when it says so exactly', () {
      expect(NetworkCost.parse('unmetered'), NetworkCost.unmetered);
      expect(NetworkCost.parse('metered'), NetworkCost.metered);
      // A value from a build that knows a third state, a null, a number:
      // an answer that cannot be read is not an answer.
      expect(NetworkCost.parse('temporarilyNotMetered'), NetworkCost.metered);
      expect(NetworkCost.parse(null), NetworkCost.metered);
      expect(NetworkCost.parse(1), NetworkCost.metered);
      expect(NetworkCost.unmetered.isUnmetered, isTrue);
      expect(NetworkCost.metered.isUnmetered, isFalse);
    });

    test('spells itself the way the platform side does', () {
      // NetworkCost.kt's UNMETERED/METERED. The two halves drift silently:
      // every reading would simply read as metered for ever.
      expect(NetworkCost.unmetered.wire, 'unmetered');
      expect(NetworkCost.metered.wire, 'metered');
    });
  });

  group('the channel', () {
    test('carries every change Android reports, not just the first', () async {
      mockNetworkChannel(['unmetered', 'metered', 'unmetered']);
      const source = ChannelNetworkCost(platform: TargetPlatform.android);

      // The whole reason this is a stream: the answer that mattered when a
      // film ended is not the answer ten minutes later. The metered in
      // front of them is what the link costs before the platform has said
      // anything, which is not nothing and is not free.
      await expectLater(
        source.costs.take(4),
        emitsInOrder([
          NetworkCost.metered,
          NetworkCost.unmetered,
          NetworkCost.metered,
          NetworkCost.unmetered,
        ]),
      );
    });

    test('answers metered when there is no platform side to ask', () async {
      mockNetworkChannel(null);
      const source = ChannelNetworkCost(platform: TargetPlatform.android);

      // And it answers rather than falling silent. A `listen` nobody
      // answers is reported to Flutter's error handler and never reaches
      // this stream, so a consumer waiting for a first reading would wait
      // for ever with the server left sharing.
      expect(await source.costs.first, NetworkCost.metered);
    });
  });

  group('a platform with nothing to ask', () {
    test('resolves without the channel, and not all the same way', () async {
      mockNetworkChannel(null);
      for (final platform in const [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          await ChannelNetworkCost(platform: platform).costs.first,
          NetworkCost.unmetered,
          reason: '$platform is on the line the building is on',
        );
      }
      // The same radio as Android and no platform side written for it, so
      // an iOS build shares nothing between sessions.
      expect(
        await const ChannelNetworkCost(platform: TargetPlatform.iOS)
            .costs
            .first,
        NetworkCost.metered,
      );
    });
  });
}
