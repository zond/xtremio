import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/downloads/download_detail.dart';
import 'package:xtremio/features/downloads/downloads_service.dart';
import 'package:xtremio/features/player/playback_engine.dart';

import '../support/fake_downloads_client.dart';
import '../support/fake_torrent_stats_client.dart';

/// One download of 100 bytes, [downloaded] of them on the device.
DownloadView viewAt(String id, int downloaded, {int size = 100}) =>
    DownloadView({
      'metaId': id,
      'videoId': id,
      'infoHash': 'abcdabcdabcdabcdabcd',
      'fileIdx': 0,
      'name': 'A Film',
      'size': size,
      'downloaded': downloaded,
      'state': size > 0 && downloaded == size ? 'complete' : 'downloading',
    });

DownloadsRegistry registryOf(Iterable<DownloadView> views) =>
    DownloadsRegistry(items: {for (final view in views) view.key: view});

/// The narrow row the Rust ticker really pushes for [view].
Map<String, dynamic> rowOf(DownloadView view) => {
  'key': view.key,
  'downloaded': view.downloaded,
  'size': view.size,
  'state': view.state.wireName,
  'path': '/downloads/a.mkv',
  'error': null,
  'completedAt': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeDownloadsClient client;
  late List<MethodCall> calls;
  late DownloadsForegroundService service;

  /// Whether the platform answers `requestNotificationPermission` yes.
  var notificationsGranted = true;

  /// Holds that answer until it completes: the question is a dialog, and
  /// it stays up for as long as the viewer leaves it.
  Completer<void>? permissionPending;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// What was asked of the platform, in order, by name.
  List<String> methods() => [for (final call in calls) call.method];

  /// Everything but the start-up question, which every run asks.
  List<String> serviceMethods() =>
      methods().where((name) => name != 'takePendingOpen').toList();

  MethodCall lastOf(String method) =>
      calls.lastWhere((call) => call.method == method);

  /// Lets the service's own futures run.
  Future<void> settle([Duration wait = const Duration(milliseconds: 30)]) =>
      Future<void>.delayed(wait);

  /// Delivers a call the way the platform side makes one.
  Future<void> fromPlatform(String method) => messenger.handlePlatformMessage(
    DownloadsForegroundService.defaultChannel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
    (_) {},
  );

  setUp(() {
    notificationsGranted = true;
    permissionPending = null;
    client = FakeDownloadsClient();
    calls = [];
    messenger.setMockMethodCallHandler(
      DownloadsForegroundService.defaultChannel,
      (call) async {
        calls.add(call);
        if (call.method == 'requestNotificationPermission') {
          await permissionPending?.future;
        }
        return switch (call.method) {
          'takePendingOpen' => false,
          'requestNotificationPermission' => notificationsGranted,
          _ => null,
        };
      },
    );
  });

  tearDown(() async {
    await service.dispose();
    await client.dispose();
    messenger.setMockMethodCallHandler(
      DownloadsForegroundService.defaultChannel,
      null,
    );
  });

  /// A service on Android unless told otherwise. Updates are not held back
  /// here: the tests about the gap between them ask for it.
  DownloadsForegroundService build({
    TargetPlatform platform = TargetPlatform.android,
    VoidCallback? openDownloads,
    DownloadDetailPoller? details,
    Duration updateGap = Duration.zero,
  }) => service = DownloadsForegroundService(
    client: client,
    platform: platform,
    openDownloads: openDownloads,
    details: details,
    updateGap: updateGap,
  );

  /// Starts the service with one download already on its way.
  Future<DownloadsForegroundService> running() async {
    client.registry = registryOf([viewAt('tt1', 25)]);
    final service = build();
    await service.start();
    await settle();
    return service;
  }

  group('what holds the service up', () {
    test('nothing downloading starts nothing', () async {
      final service = build();
      await service.start();
      await settle();

      expect(serviceMethods(), isEmpty);
      expect(service.isRunning, isFalse);
    });

    test('a download already on its way puts it up at start-up', () async {
      final service = await running();

      expect(serviceMethods(), ['start']);
      expect(service.isRunning, isTrue);
      expect(lastOf('start').arguments, {
        'title': 'Downloading A Film',
        'text': '25%',
        'progress': 25,
        'cancelLabel': kDownloadsCancelAllAction,
        'names': ['A Film'],
        'lineCounts': [2],
        'lines': ['Downloading 25%', '25 B of 100 B'],
      });
    });

    test('a download the server refused at boot puts nothing up, and its retry '
        'does', () async {
      client.registry = registryOf([
        DownloadView({
          'metaId': 'tt1',
          'videoId': 'tt1',
          'infoHash': 'abcdabcdabcdabcdabcd',
          'fileIdx': 0,
          'name': 'A Film',
          'size': 0,
          'downloaded': 0,
          'state': 'error',
          'error': 'the downloads volume is not available',
        }),
      ]);
      final service = build();
      await service.start();
      await settle();
      expect(serviceMethods(), isEmpty);
      expect(service.isRunning, isFalse);

      // Retry re-adds the entry; the first row the ticker pushes for it is
      // queued again, and that is a download starting.
      final retried = viewAt('tt1', 0, size: 0);
      client.registry = registryOf([retried]);
      client.emitProgress([rowOf(retried)]);
      await settle();

      expect(serviceMethods(), ['requestNotificationPermission', 'start']);
      expect(service.isRunning, isTrue);
    });

    test('a download that begins while the app runs starts it', () async {
      final service = build();
      await service.start();
      await settle();
      expect(service.isRunning, isFalse);

      // What really happens on an add: the entry appears in the registry and
      // the ticker's first row is the app's only hint that it did.
      final added = viewAt('tt1', 0);
      client.registry = registryOf([added]);
      client.emitProgress([rowOf(added)]);
      await settle();

      expect(serviceMethods(), ['requestNotificationPermission', 'start']);
      expect(service.isRunning, isTrue);
    });

    test('the last one finishing takes it down', () async {
      final service = await running();

      client.emitProgress([rowOf(viewAt('tt1', 100))]);
      await settle();

      expect(serviceMethods().last, 'stop');
      expect(service.isRunning, isFalse);
    });

    test('the last one being deleted takes it down', () async {
      final service = await running();

      // The Rust feed carries no event for a removal -- only rows that
      // moved -- so the client itself says what it dropped, and that is
      // what the service hears.
      await client.remove('tt1:tt1', deleteFiles: true);
      await settle();

      expect(serviceMethods().last, 'stop');
      expect(service.isRunning, isFalse);
    });

    test('the listing is read at start-up and then not on a timer', () {
      // Under a fake clock, so a minute of a download's life -- long enough
      // for any timer measured in seconds to show itself -- takes none.
      fakeAsync((async) {
        client.callLog = [];
        client.registry = registryOf([viewAt('tt1', 25)]);
        final service = build();
        unawaited(service.start());
        async.flushMicrotasks();
        expect(service.isRunning, isTrue);
        expect(client.callLog, ['downloads.list']);

        // As the feed really delivers it: a row a second, each already the
        // whole of what changed.
        for (var second = 26; second <= 85; second++) {
          client.emitProgress([rowOf(viewAt('tt1', second))]);
          async.elapse(const Duration(seconds: 1));
        }

        expect(lastOf('update').arguments, containsPair('progress', 85));
        expect(
          client.callLog,
          ['downloads.list'],
          reason:
              'the rows are the truth about progress; a listing every few '
              'seconds on top of them parsed every meta snapshot for nothing',
        );
        // Let go of inside the clock it was built under: its futures belong
        // to this zone, and one awaited from outside it never completes.
        unawaited(service.dispose());
        async.flushMicrotasks();
      });
    });

    test(
      'one of two finishing keeps it up, and moves the notification',
      () async {
        final service = await running();
        client.registry = registryOf([viewAt('tt1', 25), viewAt('tt2', 0)]);
        client.emitProgress([rowOf(viewAt('tt2', 0))]);
        await settle();
        expect(
          lastOf('update').arguments,
          containsPair('title', 'Downloading 2 titles'),
        );

        client.emitProgress([rowOf(viewAt('tt2', 100))]);
        await settle();

        expect(service.isRunning, isTrue);
        expect(serviceMethods(), isNot(contains('stop')));
        expect(
          lastOf('update').arguments,
          containsPair('title', 'Downloading A Film'),
        );
      },
    );

    test('a completion heard while a listing is taken is not lost', () async {
      // A listing is a round trip, and the ticker's last row can land
      // inside it and be overwritten by the older snapshot the listing
      // returns. Nothing resends it -- the Rust side sends a row only
      // when it changes -- so without this the service would sit at
      // its last progress until the process dies.
      final service = await running();
      final listed = Completer<void>();
      client.listPending = listed.future;
      final refreshing = service.refresh();
      await settle();

      client.emitProgress([rowOf(viewAt('tt1', 100))]);
      await settle();
      listed.complete();
      await refreshing;
      await settle();

      expect(serviceMethods().last, 'stop');
      expect(service.isRunning, isFalse);
    });

    test(
      'a download finishing while the permission is asked stops it',
      () async {
        final service = build();
        await service.start();
        await settle();
        permissionPending = Completer<void>();
        final added = viewAt('tt1', 0);
        client.registry = registryOf([added]);
        client.emitProgress([rowOf(added)]);
        await settle();
        expect(serviceMethods(), ['requestNotificationPermission']);

        // Finished before the viewer answered: the question is still on
        // screen and the start has not gone out.
        client.emitProgress([rowOf(viewAt('tt1', 100))]);
        await settle();
        permissionPending!.complete();
        await settle();

        expect(serviceMethods().last, 'stop');
        expect(service.isRunning, isFalse);
      },
    );

    test(
      'letting go while the permission is asked still takes it down',
      () async {
        final service = build();
        await service.start();
        await settle();
        permissionPending = Completer<void>();
        final added = viewAt('tt1', 0);
        client.registry = registryOf([added]);
        client.emitProgress([rowOf(added)]);
        await settle();

        final disposing = service.dispose();
        await settle();
        permissionPending!.complete();
        await disposing;

        expect(serviceMethods().last, 'stop');
      },
    );

    test('a tick that moves nothing is not sent again', () async {
      await running();
      final before = serviceMethods().length;

      client.emitProgress([rowOf(viewAt('tt1', 25))]);
      await settle();

      expect(serviceMethods().length, before);
    });

    test('the platform ending the service at its time limit is heard, and the '
        'next change asks for a new one', () async {
      final service = await running();
      expect(service.isRunning, isTrue);

      // What DownloadsService.onTimeout sends before it stops itself.
      await fromPlatform('timedOut');

      expect(service.isRunning, isFalse);
      expect(serviceMethods(), [
        'start',
      ], reason: 'a service that is gone is not sent a stop or an update');

      client.emitProgress([rowOf(viewAt('tt1', 30))]);
      await settle();

      // The same download carrying on is not a download starting, so the
      // notification question is not asked of it, as at launch.
      expect(serviceMethods(), ['start', 'start']);
      expect(service.isRunning, isTrue);
      expect(lastOf('start').arguments, containsPair('progress', 30));
    });

    test('letting go of the app takes the service down', () async {
      final service = await running();

      await service.dispose();

      expect(serviceMethods().last, 'stop');
    });
  });

  group('off Android', () {
    test('there is no service, and nothing is asked of the platform', () async {
      client.registry = registryOf([viewAt('tt1', 25)]);
      final service = build(platform: TargetPlatform.linux);
      await service.start();
      await settle();

      expect(calls, isEmpty);
      expect(service.isRunning, isFalse);
      expect(service.isSupported, isFalse);
    });

    test('and the downloads themselves are untouched', () async {
      client.registry = registryOf([viewAt('tt1', 25)]);
      final service = build(platform: TargetPlatform.linux);
      await service.start();
      await settle();

      expect(client.removed, isEmpty);
      expect(client.registry.length, 1);
    });
  });

  group('the notification permission', () {
    test('is asked for when a download starts, not before', () async {
      final service = build();
      await service.start();
      await settle();
      expect(methods(), isNot(contains('requestNotificationPermission')));

      final added = viewAt('tt1', 0);
      client.registry = registryOf([added]);
      client.emitProgress([rowOf(added)]);
      await settle();

      expect(methods(), contains('requestNotificationPermission'));
    });

    test('is not asked for at launch, whatever was left unfinished', () async {
      final service = await running();

      expect(service.isRunning, isTrue);
      expect(methods(), isNot(contains('requestNotificationPermission')));
    });

    test('is asked for once a run, however many downloads there are', () async {
      final service = build();
      await service.start();
      final first = viewAt('tt1', 0);
      client.registry = registryOf([first]);
      client.emitProgress([rowOf(first)]);
      await settle();
      await client.remove('tt1:tt1', deleteFiles: true);
      await settle();
      expect(service.isRunning, isFalse);

      final again = viewAt('tt2', 0);
      client.registry = registryOf([again]);
      client.emitProgress([rowOf(again)]);
      await settle();

      expect(
        methods()
            .where((name) => name == 'requestNotificationPermission')
            .length,
        1,
      );
    });

    test(
      'refused, the service still runs and the download is left alone',
      () async {
        notificationsGranted = false;
        final service = build();
        await service.start();
        final added = viewAt('tt1', 25);
        client.registry = registryOf([added]);
        client.emitProgress([rowOf(added)]);
        await settle();

        expect(serviceMethods(), ['requestNotificationPermission', 'start']);
        expect(service.isRunning, isTrue);
        expect(client.removed, isEmpty);
        expect(client.registry.length, 1);

        // And it keeps up with the download it cannot draw.
        client.emitProgress([rowOf(viewAt('tt1', 50))]);
        await settle();
        expect(lastOf('update').arguments, containsPair('progress', 50));
      },
    );

    test(
      'a platform that refuses the service outright breaks nothing',
      () async {
        messenger.setMockMethodCallHandler(
          DownloadsForegroundService.defaultChannel,
          (call) async {
            calls.add(call);
            if (call.method == 'start') {
              throw PlatformException(code: 'service_refused');
            }
            return call.method == 'takePendingOpen' ? false : null;
          },
        );
        final service = await running();

        expect(service.isRunning, isFalse);
        expect(client.registry.length, 1);
      },
    );
  });

  group('what the notification says', () {
    test('a length nobody knows yet is a bar with no end', () {
      final summary = DownloadsSummary.of(
        registryOf([viewAt('tt1', 40), viewAt('tt2', 0, size: 0)]),
      );

      expect(summary.active, 2);
      expect(summary.percent, isNull);
      expect(
        DownloadsNotice.of(
          registryOf([viewAt('tt1', 40), viewAt('tt2', 0, size: 0)]),
        ).toNotification()['progress'],
        -1,
      );
      expect(summary.text, '40 B so far');
    });

    test('an errored download is not something to hold it for either', () {
      // What reconcile_pins_in leaves behind when the server refuses the
      // pin at boot -- an unmounted downloads volume, a full disk: no
      // engine, no peers, nothing the process could be kept alive for.
      final refused = DownloadView({
        'metaId': 'tt2',
        'videoId': 'tt2',
        'size': 0,
        'downloaded': 0,
        'state': 'error',
        'error': 'the downloads volume is not available',
      });
      expect(
        refused.isUnfinished,
        isTrue,
        reason: 'the ticker still counts it',
      );

      expect(DownloadsSummary.of(registryOf([refused])).isIdle, isTrue);
      // Beside a download that is really on its way it is not counted, and
      // its unknown length does not make the bar endless.
      final summary = DownloadsSummary.of(
        registryOf([viewAt('tt1', 40), refused]),
      );
      expect(summary.active, 1);
      expect(summary.percent, 40);
    });

    test('and neither is one whose pieces are gone', () {
      // What the boot reconciliation leaves behind when the server does
      // not hold a finished download. Further from a download in progress
      // than an errored one: nothing is being fetched for it and nothing
      // will be until the user asks. Counting it would put a foreground
      // service up, and a "Waiting to start" notification, for a row
      // nothing is working on.
      final gone = DownloadView({
        'metaId': 'tt2',
        'videoId': 'tt2',
        'size': 100,
        'downloaded': 0,
        'state': 'gone',
        'error': 'the downloaded data is not on this device any more',
      });
      expect(
        gone.isUnfinished,
        isFalse,
        reason: 'the ticker has nothing to poll for either',
      );
      expect(DownloadsSummary.of(registryOf([gone])).isIdle, isTrue);
    });

    test('a complete or paused download is not something to hold it for', () {
      final paused = DownloadView({
        'metaId': 'tt2',
        'videoId': 'tt2',
        'size': 100,
        'downloaded': 10,
        'state': 'paused',
      });
      final summary = DownloadsSummary.of(
        registryOf([viewAt('tt1', 100), paused]),
      );

      expect(summary.isIdle, isTrue);
    });
  });

  group('what the notification says when pulled open', () {
    const connected = TorrentStats(
      phase: TorrentPhase.buffering,
      downloadSpeed: 1200000,
      peers: 14,
      swarmSeeders: 137,
      swarmLeechers: 402,
      peerDiscovery: PeerDiscovery(live: 14, seen: 80),
    );

    test('one download: its title, its percentage and speed, and the '
        'card\'s lines', () async {
      client.registry = registryOf([viewAt('tt1', 25)]);
      final stats = FakeTorrentStatsClient()..response = connected;
      final poller = DownloadDetailPoller(client: client, stats: stats);
      addTearDown(poller.dispose);
      await poller.start();
      await settle();
      build(details: poller);
      await service.start();
      await settle();

      expect(lastOf('start').arguments, {
        'title': 'Downloading A Film',
        'text': '25% · 1.2 MB/s',
        'progress': 25,
        'cancelLabel': kDownloadsCancelAllAction,
        'names': ['A Film'],
        'lineCounts': [3],
        'lines': [
          'Downloading 25%',
          '1.2 MB/s · connected 14 · seeds 137 · swarm 539',
          '25 B of 100 B',
        ],
      });
    });

    test('a phase other than downloading leads the collapsed line', () {
      final notice = DownloadsNotice.of(
        registryOf([viewAt('tt1', 0)]),
        detailOf: (view) => DownloadDetail.of(
          view,
          stats: const TorrentStats(phase: TorrentPhase.buffering),
        ),
      );
      expect(notice.text, 'Finding peers · 0%');
      expect(notice.blocks.single.lines, [
        'Finding peers',
        'No peers found yet',
        '0 B of 100 B',
      ]);
    });

    test('several: a count, the whole, and a block each', () {
      final notice = DownloadsNotice.of(
        registryOf([viewAt('tt1', 20), viewAt('tt2', 60)]),
        detailOf: (view) => DownloadDetail.of(view, stats: connected),
      );
      expect(notice.title, 'Downloading 2 titles');
      expect(notice.text, '40% · 2.4 MB/s');
      expect(notice.blocks, hasLength(2));
    });

    test('past five, the rest are counted in a line', () {
      final notice = DownloadsNotice.of(
        registryOf([for (var i = 0; i < 8; i++) viewAt('tt$i', 10)]),
      );
      expect(notice.blocks, hasLength(6));
      expect(notice.blocks.last, (
        name: 'And 3 more titles',
        lines: const <String>[],
      ));
    });

    test('a poll that changes the words updates it, and one that does not '
        'sends nothing', () {
      fakeAsync((async) {
        client.registry = registryOf([viewAt('tt1', 25)]);
        final stats = FakeTorrentStatsClient()..response = connected;
        final poller = DownloadDetailPoller(client: client, stats: stats);
        unawaited(poller.start());
        async.flushMicrotasks();
        build(details: poller, updateGap: const Duration(seconds: 2));
        unawaited(service.start());
        async.flushMicrotasks();
        expect(serviceMethods(), ['start']);

        // The same numbers, poll after poll: nothing to send.
        async.elapse(DownloadDetailPoller.cadence * 3);
        expect(serviceMethods(), ['start']);

        stats.response = const TorrentStats(phase: TorrentPhase.buffering);
        async.elapse(DownloadDetailPoller.cadence);
        expect(serviceMethods(), ['start', 'update']);
        expect(
          lastOf('update').arguments,
          containsPair(
            'text',
            'Finding '
                'peers · 25%',
          ),
        );

        unawaited(service.dispose());
        poller.dispose();
        async.flushMicrotasks();
      });
    });

    test('what arrived while held back is sent when the gap ends', () {
      fakeAsync((async) {
        client.registry = registryOf([viewAt('tt1', 25)]);
        build(updateGap: DownloadsForegroundService.defaultUpdateGap);
        unawaited(service.start());
        async.flushMicrotasks();

        client.emitProgress([rowOf(viewAt('tt1', 40))]);
        client.emitProgress([rowOf(viewAt('tt1', 60))]);
        async.flushMicrotasks();
        expect(serviceMethods(), ['start']);

        async.elapse(DownloadsForegroundService.defaultUpdateGap);
        expect(serviceMethods(), ['start', 'update']);
        expect(lastOf('update').arguments, containsPair('progress', 60));

        unawaited(service.dispose());
        async.flushMicrotasks();
      });
    });

    test('updates come at most every two seconds, and the last one is '
        'not lost', () {
      fakeAsync((async) {
        client.registry = registryOf([viewAt('tt1', 25)]);
        build(updateGap: DownloadsForegroundService.defaultUpdateGap);
        unawaited(service.start());
        async.flushMicrotasks();
        expect(serviceMethods(), ['start']);

        // A row a second, as the feed delivers them.
        for (var done = 26; done <= 30; done++) {
          client.emitProgress([rowOf(viewAt('tt1', done))]);
          async.elapse(const Duration(seconds: 1));
        }
        // Five rows in five seconds: the start, and an update at each gap.
        expect(serviceMethods(), ['start', 'update', 'update']);

        async.elapse(const Duration(seconds: 2));
        expect(lastOf('update').arguments, containsPair('progress', 30));

        // The last one finishing is not held: the service goes at once.
        client.emitProgress([rowOf(viewAt('tt1', 100))]);
        async.flushMicrotasks();
        expect(serviceMethods().last, 'stop');

        unawaited(service.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('what the notification does', () {
    test('tapping it asks for the Downloads screen', () async {
      var opened = 0;
      final service = build(openDownloads: () => opened++);
      await service.start();
      await settle();

      await fromPlatform('open');

      expect(opened, 1);
    });

    test('a tap that launched the app is collected at start-up', () async {
      messenger.setMockMethodCallHandler(
        DownloadsForegroundService.defaultChannel,
        (call) async {
          calls.add(call);
          return call.method == 'takePendingOpen' ? true : null;
        },
      );
      var opened = 0;
      final service = build(openDownloads: () => opened++);
      await service.start();
      await settle();

      expect(opened, 1);
    });

    test(
      'its action drops every unfinished download and its part-file',
      () async {
        client.registry = registryOf([
          viewAt('tt1', 25),
          viewAt('tt2', 60),
          viewAt('tt3', 100),
        ]);
        final service = build();
        await service.start();
        await settle();

        await fromPlatform('cancelAll');
        await settle();

        expect(client.removed, [
          (key: 'tt1:tt1', deleteFiles: true),
          (key: 'tt2:tt2', deleteFiles: true),
        ]);
        expect(serviceMethods().last, 'stop');
        expect(service.isRunning, isFalse);
      },
    );

    test('a download that finishes during the cancel is kept', () async {
      client.registry = registryOf([viewAt('tt1', 25), viewAt('tt2', 99)]);
      final service = build();
      await service.start();
      await settle();
      // The second one's last piece lands while the first is being
      // removed.
      client.onRemove = (key, deleteFiles) {
        if (key == 'tt1:tt1') client.emitProgress([rowOf(viewAt('tt2', 100))]);
        return DownloadRemoveResult(
          removed: true,
          unpinned: true,
          deletedFiles: deleteFiles,
        );
      };

      await fromPlatform('cancelAll');
      await settle();

      expect(client.removed, [(key: 'tt1:tt1', deleteFiles: true)]);
    });
  });
}
