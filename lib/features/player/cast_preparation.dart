import 'dart:async';

import '../cast/cast_client.dart';

/// **A rendition being made ready before the receiver is told to load it**:
/// the receiver it is for, and the server's phase. Local playback goes on
/// meanwhile, and the card over it has a Cancel.
///
/// The screen holds one for as long as the readiness asks run, and none
/// otherwise.
final class CastPreparation {
  CastPreparation(this.device);

  /// The receiver the rendition is being made for.
  final CastDevice device;

  /// What the server says it is doing (`index` first).
  String phase = 'index';

  Timer? _timer;
  Completer<void>? _wake;

  /// The wait between two readiness asks: [period], or until [wake].
  Future<void> wait(Duration period) {
    final wake = _wake = Completer<void>();
    _timer = Timer(period, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future;
  }

  /// Ends the wait at once. Cancel, Stop and leaving the screen wake the
  /// loop rather than leave it parked on a timer.
  void wake() {
    _timer?.cancel();
    _timer = null;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// The asks are over: nothing is left waiting.
  void end() {
    _timer?.cancel();
    _timer = null;
    _wake = null;
  }
}
