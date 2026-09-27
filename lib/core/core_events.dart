import 'dart:convert';

import 'fields.dart';

/// A `stremio_core::runtime::RuntimeEvent`, decoded from the JSON the Rust
/// event pump emits.
sealed class CoreEvent {
  const CoreEvent();

  /// Parses one event; never throws (unrecognized input becomes
  /// [UnknownCoreEvent] so a Rust-side change cannot break the stream).
  static CoreEvent parse(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) return CoreEvent.fromJson(decoded);
    } on FormatException {
      // fall through
    }
    return UnknownCoreEvent(json);
  }

  factory CoreEvent.fromJson(Map<String, dynamic> json) {
    final args = json['args'];
    switch (json['name']) {
      case 'NewState' when args is List:
        return NewStateEvent(args.whereType<String>().toList(growable: false));
      case 'CoreEvent' when args is Map<String, dynamic>:
        return RuntimeCoreEvent(args);
    }
    return UnknownCoreEvent(jsonEncode(json));
  }
}

/// Model fields whose state changed; re-pull them with `core_get_state`.
final class NewStateEvent extends CoreEvent {
  const NewStateEvent(this.fieldNames);

  /// Wire names, including any this client does not know yet.
  final List<String> fieldNames;

  /// The changed fields this client knows about.
  List<CoreField> get fields => [
    for (final name in fieldNames) ?CoreField.fromWireName(name),
  ];

  bool touches(CoreField field) => fieldNames.contains(field.wireName);

  @override
  String toString() => 'NewStateEvent($fieldNames)';
}

/// A `stremio_core::runtime::msg::Event` (`{"event": <name>, "args": ...}`),
/// e.g. `PlayerPlaying`, `LibraryItemAdded`, `Error`.
final class RuntimeCoreEvent extends CoreEvent {
  const RuntimeCoreEvent(this.event);

  final Map<String, dynamic> event;

  String? get name => event['event'] as String?;

  Object? get args => event['args'];

  /// The `source.event` of an `Error` event: the name of the event that
  /// failed. Null for any other event.
  String? get errorSource => _errorSource?['event'] as String?;

  /// The `source.args` of an `Error` event: the arguments of the event that
  /// failed, which for a login can be account details -- read a field of
  /// them, never log them. Null for any other event.
  Map<String, dynamic>? get errorSourceArgs {
    final args = _errorSource?['args'];
    return args is Map<String, dynamic> ? args : null;
  }

  /// The `error.message` of an `Error` event, when it has a non-empty one.
  String? get errorMessage {
    if (name != 'Error') return null;
    final args = this.args;
    if (args is! Map<String, dynamic>) return null;
    final error = args['error'];
    final message = error is Map<String, dynamic> ? error['message'] : null;
    return message is String && message.isNotEmpty ? message : null;
  }

  /// Whether this ends a library sync, done or failed: what a "Sync now"
  /// spinner waits for.
  bool get settlesLibrarySync =>
      name == 'LibrarySyncWithAPIPlanned' ||
      errorSource == 'LibrarySyncWithAPIPlanned';

  Map<String, dynamic>? get _errorSource {
    if (name != 'Error') return null;
    final args = this.args;
    if (args is! Map<String, dynamic>) return null;
    final source = args['source'];
    return source is Map<String, dynamic> ? source : null;
  }

  @override
  String toString() => 'RuntimeCoreEvent($name)';
}

/// Anything the client could not interpret; kept verbatim for logging.
final class UnknownCoreEvent extends CoreEvent {
  const UnknownCoreEvent(this.raw);

  final String raw;

  @override
  String toString() => 'UnknownCoreEvent($raw)';
}
