import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/sharing/sharing_activity.dart';

import '../support/fake_sharing.dart';

/// What the app is allowed to say about the server's traffic: only what a
/// reading says, only while it is being read, and nothing at all when the
/// reading failed.
///
/// These pump no widget and are still `testWidgets`, because what they are
/// about is a timer: the binding's clock is the fake one, so a reading
/// arrives when a test says it does rather than when the machine gets
/// round to it. The monitor is disposed inside each body, not in a
/// `tearDown`, since the binding checks for pending timers before those
/// run.
void main() {
  const period = Duration(milliseconds: 20);

  SharingActivityMonitor monitorOver(FakeSharingActivity server) =>
      SharingActivityMonitor(client: server, period: period);

  /// Lets the reading that turning the watch on started land.
  Future<void> answered(WidgetTester tester) => tester.pump();

  /// The timer's next reading, and the answer to it.
  Future<void> nextReading(WidgetTester tester) async {
    await tester.pump(period);
    await tester.pump();
  }

  testWidgets('says nothing before anybody has asked', (tester) async {
    final monitor = monitorOver(FakeSharingActivity(answer: traffic(up: true)));
    expect(monitor.active, isFalse);
    expect(monitor.uploading, isFalse);
    expect(monitor.downloading, isFalse);
    expect(monitor.reading, BackgroundTraffic.none);
    expect(monitor.watching, isFalse);
    monitor.dispose();
  });

  testWidgets('repeats the halves the server judged, and nothing else', (
    tester,
  ) async {
    // The server has already folded "nothing playing" into each half and
    // compared the counters over its own window; the monitor is a mirror
    // of that verdict, not a second judge over it.
    final server = FakeSharingActivity(answer: traffic(up: true));
    final monitor = monitorOver(server);
    monitor.watching = true;
    await answered(tester);
    expect(monitor.uploading, isTrue);
    expect(monitor.downloading, isFalse);
    expect(monitor.active, isTrue);

    server.answer = traffic(down: true);
    await nextReading(tester);
    expect(monitor.uploading, isFalse);
    expect(monitor.downloading, isTrue);
    expect(monitor.active, isTrue);

    server.answer = traffic(up: true, down: true);
    await nextReading(tester);
    expect(monitor.uploading, isTrue);
    expect(monitor.downloading, isTrue);
    expect(monitor.active, isTrue);

    server.answer = traffic();
    await nextReading(tester);
    expect(monitor.active, isFalse);
    monitor.dispose();
  });

  testWidgets('asks at once, then once a period', (tester) async {
    final server = FakeSharingActivity(answer: traffic(up: true));
    final monitor = monitorOver(server);
    monitor.watching = true;
    await answered(tester);
    expect(server.reads, 1);
    await nextReading(tester);
    await nextReading(tester);
    expect(server.reads, 3);
    monitor.dispose();
  });

  testWidgets('goes dark when the server cannot be asked', (tester) async {
    final server = FakeSharingActivity(answer: traffic(up: true, down: true));
    final monitor = monitorOver(server);
    monitor.watching = true;
    await answered(tester);
    expect(monitor.active, isTrue);

    // Not knowing is a different thing from knowing nothing is moving, and
    // it is drawn the same way, because a light that stays on says
    // something nobody can support.
    server.failure = StateError('server is not running');
    await nextReading(tester);

    expect(monitor.active, isFalse);
    expect(monitor.reading, BackgroundTraffic.none);

    // And comes back with the server, without being asked to.
    server.failure = null;
    await nextReading(tester);
    expect(monitor.active, isTrue);
    monitor.dispose();
  });

  testWidgets('stops asking, and forgets, when nobody is watching', (
    tester,
  ) async {
    final server = FakeSharingActivity(answer: traffic(up: true));
    final monitor = monitorOver(server);
    monitor.watching = true;
    await answered(tester);
    expect(monitor.active, isTrue);
    final asked = server.reads;

    monitor.watching = false;
    await nextReading(tester);
    await nextReading(tester);

    expect(server.reads, asked);
    // What it read is no longer known to be true, so it is not held on to.
    expect(monitor.active, isFalse);
    expect(monitor.reading, BackgroundTraffic.none);
    monitor.dispose();
  });
}
