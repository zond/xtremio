import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/track_menus.dart';

import '../../support/player_harness.dart';

/// The audio track picker, shown only when there is something to pick.
void main() {
  const twoTracks = PlaybackTracks(
    audio: [
      TrackInfo(
        id: '1',
        language: 'eng',
        codec: 'aac',
        channels: 'stereo',
        isDefault: true,
      ),
      TrackInfo(id: '2', title: 'Director commentary', language: 'eng'),
    ],
    activeAudioId: '1',
  );

  testWidgets('lists the tracks with their details and selects one', (
    tester,
  ) async {
    useWideViewport(tester);
    final harness = PlayerHarness();
    await harness.pump(tester);
    final engine = harness.engine;

    // One (or no) audio track: nothing to choose.
    expect(find.byTooltip('Audio track (A)'), findsNothing);
    engine.emitTracks(
      const PlaybackTracks(
        audio: [TrackInfo(id: '1', language: 'eng')],
        activeAudioId: '1',
      ),
    );
    await tester.pump();
    expect(find.byTooltip('Audio track (A)'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    expect(find.byType(AudioMenu), findsNothing);

    engine.emitTracks(twoTracks);
    await pumpEvents(tester);
    await tester.tap(find.byTooltip('Audio track (A)'));
    await tester.pumpAndSettle();
    expect(find.byType(AudioMenu), findsOneWidget);
    expect(find.text('English'), findsNWidgets(2)); // title of 1, detail of 2
    expect(find.text('stereo · aac'), findsOneWidget);
    expect(find.text('Director commentary'), findsOneWidget);
    final current = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('stereo · aac'),
        matching: find.byType(ListTile),
      ),
    );
    expect(current.selected, isTrue);

    await tester.tap(find.text('Director commentary'));
    await tester.pumpAndSettle();
    expect(engine.setAudioTrackIds, ['2']);
    expect(find.byType(AudioMenu), findsNothing);

    // The keyboard opens it too, and the pick is reflected.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    expect(find.byType(AudioMenu), findsOneWidget);
    final commentary = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Director commentary'),
        matching: find.byType(ListTile),
      ),
    );
    expect(commentary.selected, isTrue);
  });
}
