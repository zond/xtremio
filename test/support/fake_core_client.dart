import 'dart:async';
import 'dart:io';

import 'package:xtremio/core/core.dart';

/// In-memory [CoreClient] for widget tests: canned state per field, recorded
/// dispatches, and a hand-fed event stream. No FFI involved.
class FakeCoreClient implements CoreClient {
  FakeCoreClient({
    Map<CoreField, Map<String, dynamic>> state = const {},
    this.initInfo = const CoreInitInfo(serverBaseUrl: null, schemaVersion: 25),
  }) : _state = {...state};

  final Map<CoreField, Map<String, dynamic>> _state;
  final CoreInitInfo initInfo;
  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast();

  /// Every action passed to [dispatch], in order.
  final List<CoreAction> dispatched = [];

  bool _initialized = false;

  @override
  Stream<CoreEvent> get events => _events.stream;

  @override
  bool get isInitialized => _initialized;

  /// Replaces one field's state and emits the matching `NewState`.
  void setState(CoreField field, Map<String, dynamic> state) {
    _state[field] = state;
    _events.add(NewStateEvent([field.wireName]));
  }

  /// Emits an arbitrary event.
  void emit(CoreEvent event) => _events.add(event);

  @override
  Future<CoreInitInfo> init({
    required Directory support,
    required Directory cache,
    bool embeddedServer = true,
    int serverPort = kDefaultServerPort,
  }) async {
    _initialized = true;
    return initInfo;
  }

  @override
  Future<void> dispatch(CoreAction action) async {
    dispatched.add(action);
  }

  @override
  Future<Map<String, dynamic>> state(CoreField field) async =>
      _state[field] ?? const {};

  @override
  Future<void> shutdown() async {
    _initialized = false;
  }
}
