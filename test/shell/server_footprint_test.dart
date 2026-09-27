import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/shell/server_footprint.dart';

import '../support/empty_board.dart';
import '../support/fake_cast_client.dart';
import '../support/fake_deep_links.dart';
import '../support/fake_downloads_client.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_sharing.dart';

/// Every footprint the server was told, in order; [running] false plays a
/// process whose server is not up.
class RecordingServerBackground implements ServerBackgroundControl {
  final List<bool> told = [];
  bool running = true;

  @override
  bool setBackground(bool background) {
    if (!running) return false;
    told.add(background);
    return true;
  }
}

const _receiver = CastDevice(id: 'tv', name: 'Living Room TV');

/// A download in [state], as the registry lists one.
Map<String, dynamic> _download(String state) => {
  'metaId': 'tt1',
  'videoId': 'tt1',
  'type': 'movie',
  'name': 'A Film',
  'infoHash': 'abc',
  'fileIdx': 0,
  'size': 1000,
  'downloaded': state == 'complete' ? 1000 : 400,
  'state': state,
};

DownloadsRegistry _registryOf(String state) {
  final view = DownloadView(_download(state));
  return DownloadsRegistry(version: 1, items: {view.key: view});
}

void main() {
  late RecordingServerBackground server;
  late FakeDownloadsClient downloads;
  late FakeCastClient cast;
  late FakeLanMediaControl lan;

  Future<ServerFootprint> started({DownloadsRegistry? registry}) async {
    server = RecordingServerBackground();
    downloads = FakeDownloadsClient(registry: registry);
    cast = FakeCastClient();
    lan = FakeLanMediaControl();
    final footprint = ServerFootprint(
      server: server,
      downloads: downloads,
      cast: cast,
      lanMedia: lan,
    );
    addTearDown(() {
      footprint.dispose();
      cast.dispose();
      downloads.dispose();
    });
    await footprint.start();
    // The cast session's first answer arrives on a later turn.
    await pumpEventQueue();
    return footprint;
  }

  test('hidden goes lean and resumed comes back, each said once', () async {
    final footprint = await started();
    expect(server.told, isEmpty, reason: 'a fresh server is already full');

    footprint.appHidden();
    footprint.appHidden();
    expect(server.told, [true]);
    expect(footprint.isLean, isTrue);

    footprint.appResumed();
    footprint.appResumed();
    expect(server.told, [true, false]);
  });

  test(
    'a download on its way keeps the server full until it finishes',
    () async {
      final footprint = await started(registry: _registryOf('downloading'));

      footprint.appHidden();
      expect(server.told, isEmpty, reason: 'the download needs its peers');

      downloads.emitProgress([
        {
          'key': 'tt1:tt1',
          'downloaded': 1000,
          'size': 1000,
          'state': 'complete',
          'path': null,
          'error': null,
          'completedAt': null,
        },
      ]);
      await pumpEventQueue();
      expect(server.told, [true], reason: 'finished while away: lean now');
    },
  );

  test('an errored or finished download does not hold the server', () async {
    for (final state in ['error', 'complete', 'paused']) {
      final footprint = await started(registry: _registryOf(state));
      footprint.appHidden();
      expect(server.told, [true], reason: state);
    }
  });

  test(
    'a cast keeps the server full, and its end while away lets go',
    () async {
      final footprint = await started();
      cast.emitSession(_receiver);
      await pumpEventQueue();

      footprint.appHidden();
      expect(
        server.told,
        isEmpty,
        reason: 'the receiver plays from this server',
      );

      cast.emitSession(null);
      await pumpEventQueue();
      expect(server.told, [true]);
    },
  );

  test(
    'the LAN listener keeps the server full, and its stop lets go',
    () async {
      final footprint = await started();
      await footprint.setLanMedia(enabled: true);
      expect(lan.toggles, [true], reason: 'the start reaches the listener');

      footprint.appHidden();
      expect(server.told, isEmpty, reason: 'a receiver is fetching from us');

      await footprint.setLanMedia(enabled: false);
      expect(lan.toggles, [true, false]);
      expect(server.told, [true], reason: 'stopped while away: lean now');
    },
  );

  test('a server that was not running is asked again next time', () async {
    final footprint = await started();
    server.running = false;
    footprint.appHidden();
    expect(footprint.isLean, isFalse, reason: 'nobody was told');

    server.running = true;
    cast.emitSession(null);
    await pumpEventQueue();
    expect(server.told, [true]);
  });

  testWidgets('the app tells the server on hidden and on resume', (
    tester,
  ) async {
    final recorder = RecordingServerBackground();
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    await tester.pumpWidget(
      XtremioApp(
        core: emptyBoardCore(),
        deepLinks: FakeDeepLinks(),
        downloads: downloads,
        prefs: AppPrefs(client: FakePrefsClient()),
        serverSettings: RecordingServerSettings(),
        sharingActivity: FakeSharingActivity(),
        serverBackground: recorder,
      ),
    );
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(
      recorder.told,
      isEmpty,
      reason: 'an interruption is not the background',
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(recorder.told, [true]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(recorder.told, [true, false]);
  });
}
