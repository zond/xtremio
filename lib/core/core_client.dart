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

/// One fetch and one decode per field per change, shared by every reader.
///
/// Each screen keeps a [CoreFieldNotifier] on the fields it draws, and
/// several keep one on `ctx` at once -- the app, the details screen under
/// the player, the player itself, the tab beneath the stack -- so one
/// `NewState` naming `ctx` cost three or four `core_get_state` round trips
/// and three or four `jsonDecode`s of the same document on the UI isolate,
/// once per pause. Here a field is fetched and decoded once per
/// *generation*: a generation ends when a `NewState` names the field
/// ([invalidate]), and every [pull] inside one shares the same future and,
/// once it lands, the same map.
///
/// It is right whichever order the bridge delivers things in, because a
/// pull is stamped with the generation it was issued in and only ever
/// answers that one. If the engine's write landed before the pull was
/// serialized, the map already shows it and the `NewState` that follows
/// costs one extra fetch, not a stale screen. If the `NewState` lands while
/// the pull is in flight, the map still goes to whoever waited for it --
/// it is what they asked for -- and the pull the notifier makes for the new
/// generation fetches afresh.
///
/// The map is held weakly. A screen that goes away takes its copy with it,
/// as before, and a screen that arrives after the last one has gone pulls
/// again: what is shared is the work, not the memory of a board nobody is
/// looking at.
final class FieldPulls {
  FieldPulls(this._fetch);

  /// `core_get_state` by wire name, or a test's stand-in for it.
  final Future<String> Function(String wireName) _fetch;

  final Map<CoreField, _FieldPull> _pulls = {};

  /// The current JSON of [field], from the fetch in flight or the map it
  /// produced when nothing has changed since, else from a new fetch.
  Future<Map<String, dynamic>> pull(CoreField field) {
    final slot = _pulls.putIfAbsent(field, _FieldPull.new);
    final held = slot.held?.target;
    if (held != null && slot.heldGeneration == slot.generation) {
      return Future.value(held);
    }
    final inFlight = slot.inFlight;
    if (inFlight != null && slot.inFlightGeneration == slot.generation) {
      return inFlight;
    }
    final generation = slot.generation;
    final future = _fetch(field.wireName).then((json) {
      final map = jsonDecode(json) as Map<String, dynamic>;
      // A pull that lands after one issued later has nothing newer to say.
      final heldGeneration = slot.heldGeneration;
      if (heldGeneration == null || generation >= heldGeneration) {
        slot.held = WeakReference(map);
        slot.heldGeneration = generation;
      }
      return map;
    });
    slot.inFlight = future;
    slot.inFlightGeneration = generation;
    return future.whenComplete(() {
      if (slot.inFlightGeneration == generation) slot.inFlight = null;
    });
  }

  /// A `NewState` named [fields]: what was pulled for them is out of date.
  void invalidate(Iterable<CoreField> fields) {
    for (final field in fields) {
      _pulls[field]?.generation++;
    }
  }

  /// Forgets everything; for a new engine.
  void clear() => _pulls.clear();
}

class _FieldPull {
  int generation = 0;
  WeakReference<Map<String, dynamic>>? held;
  int? heldGeneration;
  Future<Map<String, dynamic>>? inFlight;
  int? inFlightGeneration;
}

/// [CoreClient] over the flutter_rust_bridge bindings.
final class RustCoreClient implements CoreClient {
  RustCoreClient();

  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast();
  StreamSubscription<String>? _rustEvents;
  final FieldPulls _pulls = FieldPulls(
    (wireName) => rust.coreGetState(field: wireName),
  );

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
    _pulls.clear();
    // Subscribe before init so the Rust side has a sink from the first
    // event; anything emitted earlier is replayed from its buffer anyway.
    // The pulls learn of a change before any listener does, so a notifier
    // that refreshes on this event never reads a map the event outdated.
    _rustEvents ??= rust.coreEvents().listen((json) {
      final event = CoreEvent.parse(json);
      if (event is NewStateEvent) _pulls.invalidate(event.fields);
      _events.add(event);
    }, onError: _events.addError);
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
  Future<Map<String, dynamic>> state(CoreField field) => _pulls.pull(field);

  @override
  Future<void> shutdown() async {
    await rust.coreShutdown();
    _pulls.clear();
  }
}
