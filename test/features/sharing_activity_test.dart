import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/sharing/sharing_activity.dart';

import '../support/fake_sharing.dart';

/// What the app is allowed to say about the server's uploading: only what a
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

  SharingActivityMonitor monitorOver(FakeSharingActivity? server) =>
      SharingActivityMonitor(client: server, period: period);

  /// Lets the reading that turning the watch on started land.
  Future<void> answered(WidgetTester tester) => tester.pump();

  /// The timer's next reading, and the answer to it.
  Future<void> nextReading(WidgetTester tester) async {
    await tester.pump(period);
    await tester.pump();
  }

  testWidgets('says nothing before anybody has asked', (tester) async {
    final monitor = monitorOver(FakeSharingActivity());
    expect(monitor.uploading, isFalse);
    expect(monitor.activity, SharingActivity.none);
    expect(monitor.watching, isFalse);
    monitor.dispose();
  });

  testWidgets('with nothing able to answer it never polls at all', (
    tester,
  ) async {
    // Which is the app as it ships; see [SharingActivityClient].
    final monitor = monitorOver(null);
    monitor.watching = true;
    await answered(tester);

    expect(monitor.watching, isFalse);
    expect(monitor.uploading, isFalse);
    monitor.dispose();
  });

  testWidgets('lights on a counter that moved, not on a rate that sampled', (
    tester,
  ) async {
    final server = FakeSharingActivity();
    // A torrent seeding steadily, reported by a rate that reads zero in the
    // gap between two pieces -- which is what a sample does and what a
    // light must not blink on.
    server.answer = const SharingActivity(torrents: 1);
    server.perRead = 32000;
    final monitor = monitorOver(server);
    monitor.watching = true;
    await answered(tester);

    // The first reading has nothing to compare against and no rate, so it
    // claims nothing; the second has bytes that really left the device.
    expect(monitor.uploading, isFalse);
    await nextReading(tester);
    expect(monitor.uploading, isTrue);
    expect(monitor.activity.torrents, 1);

    // And it goes out when the counter stops moving, however large it is.
    server.perRead = 0;
    await nextReading(tester);
    expect(monitor.uploading, isFalse);
    monitor.dispose();
  });

  testWidgets('lights on the first reading when it names a rate', (
    tester,
  ) async {
    // Nothing to compare against is not nothing to go on: a reading taken
    // mid-share reports the rate, and that is a share.
    final server = FakeSharingActivity()
      ..answer = const SharingActivity(uploadSpeed: 4000, torrents: 1);
    final monitor = monitorOver(server);
    monitor.watching = true;
    await answered(tester);

    expect(monitor.uploading, isTrue);
    monitor.dispose();
  });

  testWidgets('goes dark when the server cannot be asked', (tester) async {
    final server = FakeSharingActivity()
      ..answer = const SharingActivity(uploadSpeed: 4000, torrents: 1);
    final monitor = monitorOver(server);
    monitor.watching = true;
    await answered(tester);
    expect(monitor.uploading, isTrue);

    // Not knowing is a different thing from knowing nothing is going out,
    // and it is drawn the same way, because a light that stays on says
    // something nobody can support.
    server.failure = StateError('server is not running');
    await nextReading(tester);

    expect(monitor.uploading, isFalse);
    expect(monitor.activity, SharingActivity.none);
    monitor.dispose();
  });

  testWidgets('stops asking, and forgets, when nobody is watching', (
    tester,
  ) async {
    final server = FakeSharingActivity()
      ..answer = const SharingActivity(uploadSpeed: 4000, torrents: 1);
    final monitor = monitorOver(server);
    monitor.watching = true;
    await answered(tester);
    expect(monitor.uploading, isTrue);
    final asked = server.reads;

    monitor.watching = false;
    await nextReading(tester);
    await nextReading(tester);

    expect(server.reads, asked);
    // What it read is no longer known to be true, so it is not held on to.
    expect(monitor.uploading, isFalse);
    expect(monitor.activity, SharingActivity.none);
    monitor.dispose();
  });
}
