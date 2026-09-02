import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/rust_lib.dart';

void main() {
  setUpAll(initRustForTests);

  test(
    'boots the core against the embedded server and streams state',
    () async {
      final tmp = await Directory.systemTemp.createTemp('xtremio-core-test-');
      final client = RustCoreClient();
      addTearDown(() async {
        await client.shutdown();
        await tmp.delete(recursive: true);
      });

      expect(client.isInitialized, isFalse);

      // Listen before init so the streaming_server NewState is not missed.
      final serverState = client.events
          .where(
            (e) => e is NewStateEvent && e.touches(CoreField.streamingServer),
          )
          .first
          .timeout(const Duration(seconds: 15));

      final info = await client.init(
        support: Directory('${tmp.path}/support'),
        cache: Directory('${tmp.path}/cache'),
        serverPort: 0,
      );
      expect(client.isInitialized, isTrue);
      expect(info.schemaVersion, 25);
      expect(info.serverBaseUrl, isNotNull);
      expect(info.serverBaseUrl!.host, '127.0.0.1');
      expect(
        File('${tmp.path}/support/core/schema_version.json').existsSync(),
        isTrue,
      );

      await serverState;
      // The event may precede Ready (Loading is also a state change); poll.
      Map<String, dynamic> server = {};
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        server = await client.state(CoreField.streamingServer);
        if (server['settings']?['type'] == 'Ready') break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(server['settings']?['type'], 'Ready', reason: '$server');
      expect(server['baseUrl'], info.serverBaseUrl.toString());

      final ctx = await client.state(CoreField.ctx);
      expect(
        ctx['profile']['settings']['streamingServerUrl'],
        info.serverBaseUrl.toString(),
      );

      // Dispatch round trip + a field notifier following the change.
      final discover = CoreFieldNotifier(client, CoreField.discover);
      addTearDown(discover.dispose);
      final firstValue = discover.stream().first;
      await client.dispatch(CoreActions.unload(CoreField.discover));
      final value = await firstValue.timeout(const Duration(seconds: 5));
      expect(value, isNotNull);
      expect(value!['selected'], isNull);
      expect(discover.lastError, isNull);

      await expectLater(
        client.dispatch(
          const CoreAction(field: CoreField.board, action: {'action': 'Nope'}),
        ),
        throwsA(predicate((e) => e.toString().contains('invalid action JSON'))),
      );

      await client.shutdown();
      expect(client.isInitialized, isFalse);
      expect(const ServerClient().baseUrl, isNull);
    },
  );

  test(
    'UpdateSettings round-trips the whole map and rejects a partial one',
    () async {
      final tmp = await Directory.systemTemp.createTemp('xtremio-core-test-');
      final client = RustCoreClient();
      addTearDown(() async {
        await client.shutdown();
        await tmp.delete(recursive: true);
      });
      await client.init(
        support: Directory('${tmp.path}/support'),
        cache: Directory('${tmp.path}/cache'),
        embeddedServer: false,
      );

      final before = ProfileState.fromCtx(await client.state(CoreField.ctx))
          .settings;
      expect(before.isEmpty, isFalse);
      expect(before.bingeWatching, isTrue);
      expect(before.subtitlesSize, 100);

      await client.dispatch(
        CoreActions.updateSettings(
          before.withValue(ProfileSettings.subtitlesSizeKey, 150),
        ),
      );
      // The update is applied by the runtime's task; poll for it.
      Map<String, dynamic> after = before.json;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (after['subtitlesSize'] != 150 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        after = ProfileState.fromCtx(await client.state(CoreField.ctx))
            .settings
            .json;
      }
      expect(after, {...before.json, 'subtitlesSize': 150});

      // Settings has no serde defaults: a map with keys missing never reaches
      // the engine.
      await expectLater(
        client.dispatch(
          CoreActions.updateSettings({ProfileSettings.bingeWatchingKey: false}),
        ),
        throwsA(predicate((e) => e.toString().contains('invalid action JSON'))),
      );
      expect(
        ProfileState.fromCtx(await client.state(CoreField.ctx)).settings.json,
        {...before.json, 'subtitlesSize': 150},
      );
    },
  );
}

extension on CoreFieldNotifier {
  /// The notifier's values as they arrive.
  Stream<Map<String, dynamic>?> stream() {
    late final void Function() listener;
    final controller = StreamController<Map<String, dynamic>?>(
      onCancel: () => removeListener(listener),
    );
    listener = () => controller.add(value);
    addListener(listener);
    return controller.stream;
  }
}
