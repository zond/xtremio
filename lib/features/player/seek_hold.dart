import 'package:flutter/services.dart';

/// The acceleration of a held seek key: a tap moves the viewer's own
/// step, and holding the key moves further with every repeat.
///
/// The step is `seekTimeDuration`, a stremio-core profile setting the
/// settings screen offers and the viewer's account syncs, so nothing
/// here replaces it -- every stride is a whole number of steps, and the
/// number the viewer chose still decides how far a press goes. What was
/// wanted is "about twice as fast" and what is wanted after that is to
/// reach the other end of a film; a larger constant cannot be both, and
/// it would take the small step away from the person who set it.
///
/// This is the shape the subtitle shift already has
/// (`SubtitleTimingOverlay.shiftStrideAt`): a stride that grows with how
/// many times *this* hold has fired, so a tap is always the first stride
/// however large the one before it was. The one difference is where the
/// repeat comes from. The panel's stepper runs a timer of its own
/// because it is a button and has to answer a finger, a mouse and the
/// remote's select key at one rate; a seek key has no such press behind
/// it -- the key's own repeat *is* the hold -- so the count is taken
/// from the events, and there is no timer that could be left running
/// after the key came up.
final class SeekHold {
  /// The key this hold belongs to, so that turning round mid-hold starts
  /// again: left and right are different keys, and the press that
  /// reverses direction is a fresh one.
  LogicalKeyboardKey? _key;

  /// Repeats of [_key] before the one being answered.
  int _fires = 0;

  /// How many presses of a held key move one step before it moves two,
  /// and how many move two before it moves five.
  ///
  /// Android starts repeating a held key after 400 ms and then repeats
  /// it every 50 ms (AOSP `ViewConfiguration`: `KEY_REPEAT_DELAY = 50`,
  /// and `getKeyRepeatTimeout` is the long-press timeout, 400), so at
  /// the default ten-second step these are the distances a viewer covers
  /// by holding the key: the first ten presses are the tap and half a
  /// second of holding, and they cover a hundred seconds -- a scene.
  /// Fifteen more at two steps take three quarters of a second and cover
  /// five minutes. Everything after that moves fifty seconds a press,
  /// which is a thousand seconds of film for every second the key is
  /// held, and puts the far end of a two-hour film about seven seconds
  /// away.
  static const int singleStepFires = 10;
  static const int doubleStepFires = 15;

  /// What the [fire]th press of a held key is worth, in steps.
  static int strideAt(int fire) {
    if (fire < singleStepFires) return 1;
    if (fire < singleStepFires + doubleStepFires) return 2;
    return 5;
  }

  /// How far [event] moves, given the viewer's own [step].
  ///
  /// Unsigned: the caller knows which way the key it is answering
  /// points.
  Duration stepFor(KeyEvent event, Duration step) =>
      step * strideAt(_fireFor(event));

  int _fireFor(KeyEvent event) {
    if (event is KeyRepeatEvent && event.logicalKey == _key) return ++_fires;
    _key = event.logicalKey;
    return _fires = 0;
  }
}
