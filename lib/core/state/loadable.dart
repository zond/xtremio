/// View over stremio-core's `Loadable<R, E>` JSON
/// (`{"type": "Loading" | "Ready" | "Err", "content": ...}`).
sealed class Loadable<T> {
  const Loadable();

  /// Decodes the JSON, mapping a `Ready` payload with [ready]. Anything
  /// unrecognized is treated as still loading rather than throwing.
  factory Loadable.fromJson(
    Map<String, dynamic>? json,
    T Function(Object? content) ready,
  ) {
    switch (json?['type']) {
      case 'Ready':
        return LoadableReady<T>(ready(json!['content']));
      case 'Err':
        return LoadableError<T>(json!['content']);
      default:
        return LoadableLoading<T>();
    }
  }

  T? get contentOrNull => switch (this) {
    LoadableReady<T>(:final content) => content,
    _ => null,
  };

  bool get isLoading => this is LoadableLoading<T>;
}

final class LoadableLoading<T> extends Loadable<T> {
  const LoadableLoading();
}

final class LoadableReady<T> extends Loadable<T> {
  const LoadableReady(this.content);

  final T content;
}

final class LoadableError<T> extends Loadable<T> {
  const LoadableError(this.error);

  /// The serialized error (e.g. `{"type": "Env", "content": {...}}`).
  final Object? error;

  /// Best-effort human-readable message.
  String get message {
    final error = this.error;
    if (error is Map<String, dynamic>) {
      final content = error['content'];
      if (content is Map<String, dynamic> && content['message'] is String) {
        return content['message'] as String;
      }
      if (content is String) return content;
      return '${error['type'] ?? error}';
    }
    return '$error';
  }
}
