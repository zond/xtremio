import 'dart:async';

import 'package:flutter/foundation.dart';

/// The up-next card's countdown to the next episode: how many seconds are
/// left on it, the timer that takes them off, and what happens at zero.
///
/// It ticks once a second while the card shows and nothing holds it
/// ([mayTick]: a sheet over the player does, since the hand-over would
/// replace the sheet's route and not the player's). At zero it calls
/// [onDue]. It notifies when [secondsLeft] changes.
class UpNextCountdown extends ChangeNotifier {
  UpNextCountdown({required this.onDue, required this.mayTick});

  /// Plays the next episode. Called once, when the count runs out.
  final VoidCallback onDue;

  /// Whether the count may run now.
  final bool Function() mayTick;

  int? _secondsLeft;
  Timer? _timer;

  /// The seconds left on the card, or null when there is no card.
  int? get secondsLeft => _secondsLeft;

  /// Shows the card with [total] on it, rounded up to whole seconds, and
  /// starts the count. A [total] of zero shows no card and calls [onDue]
  /// at once: the viewer turned the countdown off.
  void start(Duration total) {
    _secondsLeft = (total.inMilliseconds / 1000).ceil();
    notifyListeners();
    resume();
  }

  /// Runs the count from what is left, when there is a card and nothing
  /// holds it.
  void resume() {
    pause();
    final left = _secondsLeft;
    if (left == null || !mayTick()) return;
    if (left <= 0) {
      onDue();
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = _secondsLeft;
      if (left == null) return;
      if (left <= 1) {
        onDue();
      } else {
        _secondsLeft = left - 1;
        notifyListeners();
      }
    });
  }

  /// Stops the count but keeps the card and the seconds left on it.
  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  /// Takes the card away, and the count with it.
  void dismiss() {
    pause();
    if (_secondsLeft == null) return;
    _secondsLeft = null;
    notifyListeners();
  }

  @override
  void dispose() {
    pause();
    super.dispose();
  }
}
