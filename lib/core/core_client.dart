import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../src/rust/api/core.dart' as rust;
import '../src/rust/api/server.dart' as rust_server;
import 'actions.dart';
import 'core_events.dart';
import 'fields.dart';
import 'server_client.dart';

/// What `core_init` reported.
final class CoreInitInfo {
  const CoreInitInfo({
    required this.serverBaseUrl,
    required this.schemaVersion,
  });

  /// Base URL of the embedded stream-server, when one was started.
  final Uri? serverBaseUrl;

  /// stremio-core's storage `SCHEMA_VERSION`.
  final int schemaVersion;
}

/// The app's handle on the stremio-core runtime.
///
/// State crosses the bridge as JSON: [dispatch] sends an action, [state]
/// pulls one model field, and [events] says which fields changed. Screens
/// build small views over the maps rather than mirroring stremio-core's
/// types. Fakeable in widget tests by implementing this interface.
abstract interface class CoreClient {
  /// Runtime events. A broadcast stream: late listeners miss earlier events,
  /// so pull the state you need once after subscribing.
  Stream<CoreEvent> get events;

  /// Whether [init] has completed and [shutdown] has not run since.
  bool get isInitialized;

  /// Boots the engine (idempotent), starting the embedded server first when
  /// [embeddedServer] is set. [support] and [cache] are the app's support
  /// and cache directories; the core and server get subdirectories.
  Future<CoreInitInfo> init({
    required Directory support,
    required Directory cache,
    bool embeddedServer = true,
    int serverPort = kDefaultServerPort,
  });

  Future<void> dispatch(CoreAction action);

  /// The current JSON of one model field.
  Future<Map<String, dynamic>> state(CoreField field);

  /// Stops the engine and the embedded server.
  Future<void> shutdown();
}

/// [CoreClient] over the flutter_rust_bridge bindings.
final class RustCoreClient implements CoreClient {
  RustCoreClient();

  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast();
  StreamSubscription<String>? _rustEvents;

  @override
  Stream<CoreEvent> get events => _events.stream;

  @override
  bool get isInitialized => rust.coreIsInitialized();

  @override
  Future<CoreInitInfo> init({
    required Directory support,
    required Directory cache,
    bool embeddedServer = true,
    int serverPort = kDefaultServerPort,
  }) async {
    // Subscribe before init so the Rust side has a sink from the first
    // event; anything emitted earlier is replayed from its buffer anyway.
    _rustEvents ??= rust.coreEvents().listen(
      (json) => _events.add(CoreEvent.parse(json)),
      onError: _events.addError,
    );
    final result = await rust.coreInit(
      config: rust.CoreConfig(
        storageDir: '${support.path}/core',
        cacheDir: '${cache.path}/core',
        server: embeddedServer
            ? rust_server.ServerConfig(
                configDir: '${support.path}/server',
                cacheDir: '${cache.path}/server',
                port: serverPort,
                fallbackToEphemeral: true,
              )
            : null,
      ),
    );
    final url = result.serverBaseUrl;
    return CoreInitInfo(
      serverBaseUrl: url == null ? null : Uri.parse(url),
      schemaVersion: result.schemaVersion,
    );
  }

  @override
  Future<void> dispatch(CoreAction action) =>
      rust.coreDispatch(actionJson: jsonEncode(action.toJson()));

  @override
  Future<Map<String, dynamic>> state(CoreField field) async {
    final json = await rust.coreGetState(field: field.wireName);
    return jsonDecode(json) as Map<String, dynamic>;
  }

  @override
  Future<void> shutdown() => rust.coreShutdown();
}
