import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';

import '../../support/fake_playback_engine.dart';

/// What [PlaybackScope] tells the widgets under it when a seam changes.
void main() {
  testWidgets('a new router reader reaches the screens that read it', (
    tester,
  ) async {
    const off = PortForwardingStatus(
      enabled: false,
      searched: false,
      held: false,
    );
    const held = PortForwardingStatus(
      enabled: true,
      searched: true,
      port: 45810,
      held: true,
    );
    final seen = <PortForwardingStatus>[];
    // One child instance across both pumps, so only the scope's own notice
    // can rebuild it.
    final child = Builder(
      builder: (context) {
        seen.add(PlaybackScope.portForwardingStatusOf(context)());
        return const SizedBox();
      },
    );
    Widget scope(PortForwardingStatus Function() read) => PlaybackScope(
      createEngine: FakePlaybackEngine.new,
      portForwardingStatus: read,
      child: child,
    );

    await tester.pumpWidget(scope(() => off));
    await tester.pumpWidget(scope(() => held));

    expect(seen, [off, held]);
  });
}
