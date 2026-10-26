import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/subtitle_auto_pick.dart';

/// The auto-pick's standing on its own. What it puts on screen is held by
/// player_subtitle_picks_test and player_subtitles_test.
void main() {
  test('starts open, with nothing on screen', () {
    final pick = SubtitleAutoPick();
    expect(pick.mayPick, isTrue);
    expect(pick.rank, isNull);
    expect(pick.byHand, isFalse);
  });

  test('closed while a pick is in flight, open again once answered', () {
    final pick = SubtitleAutoPick()..applying();
    expect(pick.mayPick, isFalse);
    pick.answered();
    expect(pick.mayPick, isTrue);
  });

  test('an accepted pick stands at its rank and settles when told', () {
    final pick = SubtitleAutoPick()
      ..applying()
      ..accepted(2, settles: false)
      ..answered();
    expect(pick.rank, 2);
    expect(pick.mayPick, isTrue, reason: 'a better file may still come');
    pick
      ..applying()
      ..accepted(3, settles: true)
      ..answered();
    expect(pick.mayPick, isFalse);
  });

  test('settles only once something is on screen', () {
    final pick = SubtitleAutoPick()..settle();
    expect(pick.mayPick, isTrue);
    pick
      ..accepted(1, settles: false)
      ..settle();
    expect(pick.mayPick, isFalse);
  });

  test('a refused file reopens the pick at the rank it replaced', () {
    final pick = SubtitleAutoPick()
      ..accepted(1, settles: false)
      ..accepted(3, settles: true)
      ..refused(1);
    expect(pick.rank, 1);
    expect(pick.mayPick, isTrue);
  });

  test('a choice by hand closes it for good, even mid-flight', () {
    final pick = SubtitleAutoPick()
      ..applying()
      ..chooseByHand()
      ..accepted(3, settles: false)
      ..answered()
      ..refused(null);
    expect(pick.byHand, isTrue);
    expect(pick.mayPick, isFalse);
  });
}
