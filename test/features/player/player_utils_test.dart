import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/player/time_format.dart';

void main() {
  test(
    'formatTime uses m:ss under an hour, h:mm:ss above, - for remaining',
    () {
      expect(formatTime(Duration.zero), '0:00');
      expect(formatTime(const Duration(seconds: 65)), '1:05');
      expect(formatTime(const Duration(minutes: 96)), '1:36:00');
      expect(formatTime(const Duration(hours: 10, seconds: 3)), '10:00:03');
      expect(formatTime(const Duration(minutes: -5, seconds: -7)), '-5:07');
    },
  );

  test('PlaybackTracks.copyWith changes selections only', () {
    const tracks = PlaybackTracks(
      audio: [TrackInfo(id: '1')],
      subtitle: [TrackInfo(id: '3')],
      activeAudioId: '1',
      activeSubtitleId: '3',
    );
    expect(tracks.copyWith(activeAudioId: '2').activeAudioId, '2');
    expect(tracks.copyWith(activeAudioId: '2').activeSubtitleId, '3');
    expect(tracks.copyWith(clearSubtitle: true).activeSubtitleId, isNull);
    expect(tracks.copyWith(clearSubtitle: true).audio, tracks.audio);
    expect(tracks, tracks.copyWith());
  });

  test('SubtitleStyle copyWith and equality', () {
    const style = SubtitleStyle();
    expect(style.copyWith(fontSize: 40), const SubtitleStyle(fontSize: 40));
    expect(style.copyWith(background: false), isNot(style));
    expect(style.copyWith(), style);
  });
}
