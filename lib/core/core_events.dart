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
