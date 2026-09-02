import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_client.dart';
import 'core_events.dart';
import 'fields.dart';

/// Keeps the latest JSON of one model field, re-pulling it whenever a
/// `NewState` event names the field. Pulls are coalesced: a burst of events
/// within one event-loop turn results in a single `core_get_state`, and a
/// pull that finishes after a newer request was made is followed by one more.
///
/// The value is null until the first pull completes.
class CoreFieldNotifier extends ValueNotifier<Map<String, dynamic>?> {
  CoreFieldNotifier(this.client, this.field) : super(null) {
    _subscription = client.events.listen(_onEvent);
    refresh();
  }

  final CoreClient client;
  final CoreField field;

  StreamSubscription<CoreEvent>? _subscription;
  bool _pullScheduled = false;
  bool _pulling = false;
  bool _dirty = false;
  bool _disposed = false;
  Object? _lastError;

  /// The error of the most recent failed pull, cleared by a successful one.
  Object? get lastError => _lastError;

  void _onEvent(CoreEvent event) {
    if (event is NewStateEvent && event.touches(field)) refresh();
  }

  /// Requests a pull (coalesced with other pending requests).
  void refresh() {
    if (_disposed) return;
    if (_pulling) {
      _dirty = true;
      return;
    }
    if (_pullScheduled) return;
    _pullScheduled = true;
    scheduleMicrotask(_pull);
  }

  Future<void> _pull() async {
    _pullScheduled = false;
    if (_disposed) return;
    _pulling = true;
    try {
      final next = await client.state(field);
      if (_disposed) return;
      _lastError = null;
      value = next;
    } catch (error) {
      if (_disposed) return;
      _lastError = error;
      notifyListeners();
    } finally {
      _pulling = false;
    }
    if (_dirty) {
      _dirty = false;
      refresh();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }
}
