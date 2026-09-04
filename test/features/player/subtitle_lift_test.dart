import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// [SubtitleLift]: what [MediaKitEngine.buildVideo] asks before it pushes a
/// padding into media_kit's live subtitle view (pure data; no libmpv).
///
/// The push exists because `SubtitleView` copies the padding out of its
/// configuration once, when its state is created, and never looks at the
/// configuration's padding again -- so the OSD coming up and going away
/// cannot move the subtitles by rebuilding with another configuration.
void main() {
  const rest = EdgeInsets.fromLTRB(16, 0, 16, 24);
  const lifted = EdgeInsets.fromLTRB(16, 0, 16, 144);

  test('the first padding of a session is pushed as well as configured', () {
    final lift = SubtitleLift();
    expect(lift.showing, isNull);
    expect(lift.changedTo(rest), isTrue);
    expect(lift.showing, rest);
  });

  test('a change is pushed once, and a repeat of it never', () {
    final lift = SubtitleLift();
    lift.changedTo(rest);

    // The player screen rebuilds on every position tick, and each of those
    // builds hands the same padding back. Pushing it is a `setState` on the
    // subtitle view, so only a change is worth one.
    expect(lift.changedTo(rest), isFalse);
    expect(lift.changedTo(lifted), isTrue);
    expect(lift.changedTo(lifted), isFalse);
    expect(lift.showing, lifted);

    // Back down again is a change like any other: the OSD faded.
    expect(lift.changedTo(rest), isTrue);
    expect(lift.showing, rest);
  });
}
