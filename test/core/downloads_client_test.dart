import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_downloads_client.dart';
import '../support/fixtures.dart';

/// A [RustDownloadsClient] over recorded answers instead of the FFI: the
/// generated functions are what it stands on, and standing them in is how
/// the encoding and the parsing get tested without pinning a torrent.
class _Recorder {
  final List<String> addRequests = [];
  final List<({String key, bool deleteFiles})> removals = [];
  final List<String?> directories = [];
  int lists = 0;
  int settingsReads = 0;

  /// How many times the progress stream was opened. The Rust side keeps one
  /// event sink, so this must never go past 1 for one client.
  int opened = 0;

  final StreamController<String> events = StreamController<String>.broadcast();

  String addAnswer = '{"ok":true,"key":"tt1:tt1","entry":{"metaId":"tt1"}}';
  String removeAnswer = '{"removed":true,"unpinned":true,"deletedFiles":false}';
  String listAnswer = '{"version":1,"items":{}}';
  String setDirAnswer = '{"downloadsDir":null}';
  String settingsAnswer = '{"downloadsDir":null,"cacheSize":2147483648}';

  RustDownloadsClient get client => RustDownloadsClient(
    addDownload: ({required String requestJson}) async {
      addRequests.add(requestJson);
      return addAnswer;
    },
    removeDownload: ({required String key, required bool deleteFiles}) async {
      removals.add((key: key, deleteFiles: deleteFiles));
      return removeAnswer;
    },
    listDownloads: () async {
      lists++;
      return listAnswer;
    },
    setDownloadsDir: ({String? path}) async {
      directories.add(path);
      return setDirAnswer;
    },
    readSettings: () async {
      settingsReads++;
      return settingsAnswer;
    },
    openEvents: () {
      opened++;
      return events.stream;
    },
  );
}

DownloadRequest _request() => DownloadRequest(
  metaId: 'tt0903747',
  videoId: 'tt0903747:1:1',
  type: 'series',
  name: 'Breaking Bad: Pilot',
  poster: 'https://images.metahub.space/poster/medium/tt0903747/img',
  stream: const StreamInfo({
    'infoHash': 'abc',
    'fileIdx': 3,
    'announce': ['udp://tracker.invalid:1337/announce'],
  }),
  meta: const {'id': 'tt0903747', 'name': 'Breaking Bad'},
  streamRequest: const {'base': 'https://torrentio.invalid/manifest.json'},
  metaRequest: const {'base': 'https://v3-cinemeta.strem.io/manifest.json'},
);

void main() {
  late _Recorder rust;

  setUp(() => rust = _Recorder());
  tearDown(() => rust.events.close());

  group('RustDownloadsClient', () {
    test('add hands the Rust side the request as it takes it', () async {
      await rust.client.add(_request());

      expect(rust.addRequests, hasLength(1));
      final sent = jsonDecode(rust.addRequests.single) as Map<String, dynamic>;
      expect(sent['metaId'], 'tt0903747');
      expect(sent['videoId'], 'tt0903747:1:1');
      expect(sent['type'], 'series');
      expect(sent['name'], 'Breaking Bad: Pilot');
      expect(sent['poster'], contains('tt0903747'));
      expect(sent['stream'], {
        'infoHash': 'abc',
        'fileIdx': 3,
        'announce': ['udp://tracker.invalid:1337/announce'],
      });
      expect(sent['meta'], {'id': 'tt0903747', 'name': 'Breaking Bad'});
      expect(sent['streamRequest'], {
        'base': 'https://torrentio.invalid/manifest.json',
      });
      expect(sent['metaRequest'], {
        'base': 'https://v3-cinemeta.strem.io/manifest.json',
      });
      expect(
        sent.containsKey('fileIdx'),
        isFalse,
        reason: 'no index given means the server picks the file that plays',
      );
    });

    test(
      'an index the caller resolved itself is sent, and overrides',
      () async {
        final request = DownloadRequest(
          metaId: 'tt1',
          videoId: 'tt1',
          fileIdx: 7,
          stream: const StreamInfo({'infoHash': 'abc', 'fileIdx': 3}),
        );
        await rust.client.add(request);

        final sent =
            jsonDecode(rust.addRequests.single) as Map<String, dynamic>;
        expect(sent['fileIdx'], 7);
        expect((sent['stream'] as Map<String, dynamic>)['fileIdx'], 3);
        expect(request.key, 'tt1:tt1');
      },
    );

    test('a taken pin comes back as the entry it recorded', () async {
      rust.addAnswer = jsonEncode({
        'ok': true,
        'key': 'tt0063350:tt0063350',
        'entry': loadDownloadsFixture()['items']['tt0063350:tt0063350'],
      });

      final result = await rust.client.add(_request());
      expect(result.ok, isTrue);
      expect(result.key, 'tt0063350:tt0063350');
      expect(result.error, isNull);
      expect(result.entry!.state, DownloadState.complete);
      expect(result.entry!.name, 'Night of the Living Dead');
    });

    test(
      'a refused pin is a value with its numbers, not an exception',
      () async {
        rust.addAnswer = jsonEncode({
          'ok': false,
          'key': 'tt1:tt1',
          'error': {
            'kind': 'insufficientSpace',
            'required': 4000000000,
            'available': 1000000000,
            'margin': 524288000,
            'message': 'not enough free space for this download',
          },
        });

        final result = await rust.client.add(_request());
        expect(result.ok, isFalse);
        expect(result.entry, isNull);
        final error = result.error!;
        expect(error.kind, DownloadFailureKind.insufficientSpace);
        expect(error.message, 'not enough free space for this download');
        expect(error.requiredBytes, 4000000000);
        expect(error.availableBytes, 1000000000);
        expect(error.marginBytes, 524288000);
        expect(DownloadView.humanSize(error.requiredBytes!), '4.0 GB');
      },
    );

    test('every refusal kind reads back, and a newer one is not fatal', () {
      for (final kind in DownloadFailureKind.values) {
        if (kind == DownloadFailureKind.unknown) continue;
        expect(DownloadFailureKind.parse(kind.wireName), kind);
      }
      const missing = DownloadFailure({
        'kind': 'fileNotFound',
        'fileIdx': 99,
        'fileCount': 2,
        'message': 'the torrent has no file 99',
      });
      expect(missing.kind, DownloadFailureKind.fileNotFound);
      expect(missing.fileIdx, 99);
      expect(missing.fileCount, 2);
      expect(
        const DownloadFailure({'kind': 'diskOnFire'}).kind,
        DownloadFailureKind.unknown,
      );
      expect(const DownloadFailure({}).message, '');
    });

    test(
      'remove passes the key and the flag, and answers what happened',
      () async {
        rust.removeAnswer =
            '{"removed":true,"unpinned":false,"deletedFiles":false}';

        final client = rust.client;
        final result = await client.remove('tt1:tt1', deleteFiles: true);
        await client.remove('tt2:tt2');

        expect(rust.removals, [
          (key: 'tt1:tt1', deleteFiles: true),
          (key: 'tt2:tt2', deleteFiles: false),
        ]);
        expect(result.removed, isTrue);
        expect(
          result.unpinned,
          isFalse,
          reason: 'another download names the same file',
        );
        expect(result.deletedFiles, isFalse);
      },
    );

    test('list parses the registry the Rust side answers with', () async {
      rust.listAnswer = jsonEncode(loadDownloadsFixture());

      final registry = await rust.client.list();
      expect(rust.lists, 1);
      expect(registry.length, 3);
      expect(registry['tt0063350:tt0063350']!.isComplete, isTrue);
    });

    test('setDirectory passes the path, and null to unset it', () async {
      rust.setDirAnswer = '{"downloadsDir":"/media/sd/xtremio"}';

      final client = rust.client;
      final settings = await client.setDirectory('/media/sd/xtremio');
      await client.setDirectory(null);

      expect(rust.directories, ['/media/sd/xtremio', null]);
      expect(settings['downloadsDir'], '/media/sd/xtremio');
    });

    test('directory reads the destination out of the settings', () async {
      rust.settingsAnswer = '{"downloadsDir":"/media/sd/xtremio"}';
      expect(await rust.client.directory(), '/media/sd/xtremio');
      expect(rust.settingsReads, 1);

      rust.settingsAnswer = '{"cacheSize":2147483648}';
      expect(
        await rust.client.directory(),
        isNull,
        reason: 'unset means the torrent cache',
      );
    });

    test('a retry sends the entry back as the request that made it', () async {
      final view = DownloadView(
        loadDownloadsFixture()['items']['tt0903747:tt0903747:1:1']
            as Map<String, dynamic>,
      );

      await rust.client.add(DownloadRequest.fromView(view));

      final sent = jsonDecode(rust.addRequests.single) as Map<String, dynamic>;
      expect(sent['metaId'], 'tt0903747');
      expect(sent['videoId'], 'tt0903747:1:1');
      expect(sent['type'], 'series');
      expect(sent['name'], 'Breaking Bad: Pilot');
      expect(sent['stream'], view.stream.json);
      expect(sent['meta'], view.meta);
      expect(sent['streamRequest'], view.streamRequest);
      expect(sent['metaRequest'], view.metaRequest);
      expect(
        sent['fileIdx'],
        view.fileIdx,
        reason: 'the file already half on disk, not another guess',
      );
    });
  });

  group('the progress stream', () {
    test('is opened once and shared, whoever listens', () async {
      final client = rust.client;
      final first = <int>[];
      final second = <int>[];
      client.updates.listen((update) => first.add(update.length));
      client.updates.listen((update) => second.add(update.length));
      await pumpEventQueue();

      rust.events.add('{"version":1,"items":{"a:b":{"metaId":"a"}}}');
      await pumpEventQueue();

      expect(rust.opened, 1, reason: 'the Rust side keeps one event sink');
      expect(first, [1]);
      expect(second, [1]);
    });

    test('carries only what moved, to lay over a full listing', () async {
      rust.listAnswer = jsonEncode(loadDownloadsFixture());
      final client = rust.client;
      final full = await client.list();
      final seen = <DownloadsRegistry>[];
      client.updates.listen(seen.add);
      await pumpEventQueue();

      rust.events.add(
        jsonEncode({
          'version': 1,
          'items': {
            'tt0903747:tt0903747:1:1': {
              'metaId': 'tt0903747',
              'videoId': 'tt0903747:1:1',
              'size': 49152,
              'downloaded': 49152,
              'state': 'complete',
            },
          },
        }),
      );
      await pumpEventQueue();

      expect(seen.single.length, 1);
      final merged = full.merge(seen.single);
      expect(merged.length, 3);
      expect(merged['tt0903747:tt0903747:1:1']!.progress, 1);
    });

    test('a payload this build cannot read is skipped, not fatal', () async {
      final client = rust.client;
      final seen = <DownloadsRegistry>[];
      final errors = <Object>[];
      client.updates.listen(seen.add, onError: errors.add);
      await pumpEventQueue();

      rust.events.add('not json at all');
      rust.events.add('[1,2,3]');
      rust.events.add('{"version":1,"items":{"a:b":{"metaId":"a"}}}');
      await pumpEventQueue();

      expect(seen, hasLength(1));
      expect(errors, isEmpty);
    });

    test('an error from the Rust stream reaches the listener', () async {
      final client = rust.client;
      final errors = <Object>[];
      client.updates.listen((_) {}, onError: errors.add);
      await pumpEventQueue();

      rust.events.addError(StateError('the server went away'));
      await pumpEventQueue();

      expect(errors, hasLength(1));
    });

    test(
      'the Rust stream ending ends the feed, it does not go quiet',
      () async {
        final client = rust.client;
        addTearDown(client.dispose);
        var done = false;
        client.updates.listen((_) {}, onDone: () => done = true);
        await pumpEventQueue();
        expect(rust.opened, 1);

        // The Rust side keeps one event sink: a second client replaces it and
        // this stream ends under the first one.
        await rust.events.close();
        await pumpEventQueue();

        expect(done, isTrue, reason: 'a listener is told, not left waiting');

        // And whoever was told can ask for the feed again.
        client.updates.listen((_) {});
        await pumpEventQueue();
        expect(rust.opened, 2);
      },
    );

    test('dispose lets go of the Rust stream and stays let go', () async {
      final client = rust.client;
      final seen = <DownloadsRegistry>[];
      client.updates.listen(seen.add);
      await pumpEventQueue();
      expect(rust.events.hasListener, isTrue);

      await client.dispose();
      await pumpEventQueue();
      expect(rust.events.hasListener, isFalse);

      rust.events.add('{"version":1,"items":{"a:b":{"metaId":"a"}}}');
      await pumpEventQueue();
      expect(seen, isEmpty);

      // And asking again does not quietly open a second sink.
      final after = <DownloadsRegistry>[];
      client.updates.listen(after.add);
      await pumpEventQueue();
      expect(rust.opened, 1);
      expect(after, isEmpty);
    });

    test('a client nobody listened to opens nothing to dispose', () async {
      await rust.client.dispose();
      expect(rust.opened, 0);
    });
  });

  group('DownloadsScope', () {
    testWidgets('hands the client down the tree', (tester) async {
      final client = FakeDownloadsClient();
      late DownloadsClient found;
      await tester.pumpWidget(
        DownloadsScope(
          client: client,
          child: Builder(
            builder: (context) {
              found = DownloadsScope.of(context);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(found, same(client));
    });

    testWidgets('with no scope there is nothing to conjure', (tester) async {
      DownloadsClient? found;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            found = DownloadsScope.maybeOf(context);
            return const SizedBox();
          },
        ),
      );

      expect(found, isNull);
    });
  });

  group('FakeDownloadsClient', () {
    test('onRemove reaches the outcome the default cannot', () async {
      final client = FakeDownloadsClient(
        registry: DownloadsRegistry.fromJson(loadDownloadsFixture()),
      );
      addTearDown(client.dispose);
      // One torrent under two metas: the row goes, the file is the other
      // download's and stays.
      client.onRemove = (key, deleteFiles) => const DownloadRemoveResult(
        removed: true,
        unpinned: false,
        deletedFiles: false,
      );

      final result = await client.remove(
        'tt0063350:tt0063350',
        deleteFiles: true,
      );

      expect(result.removed, isTrue);
      expect(result.unpinned, isFalse);
      expect(result.deletedFiles, isFalse);
      expect(client.removed.single, (
        key: 'tt0063350:tt0063350',
        deleteFiles: true,
      ), reason: 'the call is still recorded');
      expect((await client.list())['tt0063350:tt0063350'], isNull);
    });

    test('a removal onRemove refuses leaves the row where it was', () async {
      final client = FakeDownloadsClient(
        registry: DownloadsRegistry.fromJson(loadDownloadsFixture()),
      );
      addTearDown(client.dispose);
      client.onRemove = (key, deleteFiles) => const DownloadRemoveResult(
        removed: false,
        unpinned: false,
        deletedFiles: false,
      );

      expect((await client.remove('tt0063350:tt0063350')).removed, isFalse);
      expect((await client.list())['tt0063350:tt0063350'], isNotNull);
    });

    test('accepts a download, then lists and removes it', () async {
      final client = FakeDownloadsClient();
      addTearDown(client.dispose);

      final result = await client.add(_request());
      expect(result.ok, isTrue);
      expect(result.entry!.key, 'tt0903747:tt0903747:1:1');
      expect(result.entry!.fileIdx, 3, reason: "the stream's own index");
      expect(result.entry!.state, DownloadState.queued);
      expect(client.added.single.metaId, 'tt0903747');

      final listed = await client.list();
      expect(listed.length, 1);

      final removed = await client.remove('tt0903747:tt0903747:1:1');
      expect(removed.removed, isTrue);
      expect(client.removed.single.deleteFiles, isFalse);
      expect((await client.list()).isEmpty, isTrue);
      expect((await client.remove('nothing:here')).removed, isFalse);
    });

    test('pushes progress the way the ticker does', () async {
      final client = FakeDownloadsClient(
        registry: DownloadsRegistry.fromJson(loadDownloadsFixture()),
      );
      addTearDown(client.dispose);
      final seen = <DownloadsRegistry>[];
      client.updates.listen(seen.add);
      await pumpEventQueue();

      client.emitEntry(const {
        'metaId': 'tt0903747',
        'videoId': 'tt0903747:1:1',
        'size': 49152,
        'downloaded': 49152,
        'state': 'complete',
      });
      await pumpEventQueue();

      expect(seen.single.length, 1);
      expect(
        (await client.list())['tt0903747:tt0903747:1:1']!.isComplete,
        isTrue,
        reason: 'and the list agrees with what the listeners saw',
      );
    });

    test('a refusal and a thrown call are both arrangeable', () async {
      final client = FakeDownloadsClient();
      addTearDown(client.dispose);
      client.onAdd = (request) => DownloadAddResult.fromJson({
        'ok': false,
        'key': request.key,
        'error': {'kind': 'backend', 'message': 'the engine refused the pin'},
      });

      final refused = await client.add(_request());
      expect(refused.ok, isFalse);
      expect(refused.error!.kind, DownloadFailureKind.backend);
      expect((await client.list()).isEmpty, isTrue);

      client.listError = StateError('the server is not running');
      await expectLater(client.list(), throwsStateError);
    });

    test('records the destination it was pointed at', () async {
      final client = FakeDownloadsClient();
      addTearDown(client.dispose);

      final settings = await client.setDirectory('/media/sd/xtremio');
      expect(client.directories, ['/media/sd/xtremio']);
      expect(settings['downloadsDir'], '/media/sd/xtremio');

      await client.dispose();
      expect(client.disposed, isTrue);
    });
  });
}
