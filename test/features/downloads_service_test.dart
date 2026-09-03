import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/downloads/downloads_service.dart';

import '../support/fake_downloads_client.dart';

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

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// What was asked of the platform, in order, by name.
  List<String> methods() => [for (final call in calls) call.method];

  /// Everything but the start-up question, which every run asks.
  List<String> serviceMethods() =>
      methods().where((name) => name != 'takePendingOpen').toList();

  MethodCall lastOf(String method) =>
      calls.lastWhere((call) => call.method == method);

  /// Lets the service's own futures and its listing timer run.
  Future<void> settle([Duration wait = const Duration(milliseconds: 30)]) =>
      Future<void>.delayed(wait);

  setUp(() {
    notificationsGranted = true;
    client = FakeDownloadsClient();
    calls = [];
    messenger.setMockMethodCallHandler(
      DownloadsForegroundService.defaultChannel,
      (call) async {
        calls.add(call);
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

  /// A service on Android unless told otherwise, with a listing timer fast
  /// enough for a test to wait on.
  DownloadsForegroundService build({
    TargetPlatform platform = TargetPlatform.android,
    VoidCallback? openDownloads,
  }) => service = DownloadsForegroundService(
    client: client,
    platform: platform,
    openDownloads: openDownloads,
    listingInterval: const Duration(milliseconds: 10),
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

      expect(serviceMethods(), ['requestNotificationPermission', 'start']);
      expect(service.isRunning, isTrue);
      expect(lastOf('start').arguments, {
        'title': 'Downloading 1 title',
        'text': '25 B of 100 B · 25%',
        'progress': 25,
        'cancelLabel': kDownloadsCancelAllAction,
      });
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

      // A removal has no event of its own -- the feed only carries rows that
      // moved -- so the listing the service re-reads is what notices.
      client.registry = DownloadsRegistry.empty;
      await settle();

      expect(serviceMethods().last, 'stop');
      expect(service.isRunning, isFalse);
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
          containsPair('title', 'Downloading 1 title'),
        );
      },
    );

    test('a tick that moves nothing is not sent again', () async {
      await running();
      final before = serviceMethods().length;

      client.emitProgress([rowOf(viewAt('tt1', 25))]);
      await settle();

      expect(serviceMethods().length, before);
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

    test('is asked for once a run, however many downloads there are', () async {
      final service = await running();
      client.registry = DownloadsRegistry.empty;
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
        final service = await running();

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
      expect(summary.toNotification()['progress'], -1);
      expect(summary.text, '40 B so far');
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

  group('what the notification does', () {
    /// Delivers a call the way the platform side makes one.
    Future<void> fromPlatform(String method) => messenger.handlePlatformMessage(
      DownloadsForegroundService.defaultChannel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (_) {},
    );

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
  });
}
