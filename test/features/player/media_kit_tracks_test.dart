import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// How [MediaKitEngine] derives the active tracks from media_kit's track
/// list and selection plus mpv's own `aid`/`sid` (pure data; no libmpv).
void main() {
  const tracks = Tracks(
    audio: [
      AudioTrack('auto', null, null),
      AudioTrack('no', null, null),
      AudioTrack('1', null, 'eng'),
      AudioTrack('2', 'Commentary', 'eng'),
    ],
    subtitle: [
      SubtitleTrack('auto', null, null),
      SubtitleTrack('no', null, null),
      SubtitleTrack('3', null, 'eng', isDefault: true),
      SubtitleTrack('4', 'https://subs.example/fre.srt', 'fre'),
    ],
  );
  const external = {'https://subs.example/fre.srt'};

  PlaybackTracks merge({
    Track selected = const Track(),
    String? aid,
    String? sid,
  }) => MediaKitEngine.mergeTracks(
    tracks: tracks,
    selected: selected,
    mpvAudioId: aid,
    mpvSubtitleId: sid,
    externalSubtitleUrls: external,
  );

  test(
    'lists real tracks only; externals are kept out of the embedded list',
    () {
      final merged = merge();
      expect([for (final t in merged.audio) t.id], ['1', '2']);
      expect(merged.audio.last.title, 'Commentary');
      expect([for (final t in merged.subtitle) t.id], ['3']);
      expect(merged.subtitle.single.isDefault, isTrue);
      expect(merged.activeAudioId, isNull);
      expect(merged.activeSubtitleId, isNull);
    },
  );

  test("mpv's own selection wins over media_kit's, once observed", () {
    // A default subtitle mpv picked by itself: media_kit still says auto.
    expect(merge(sid: '3', aid: '1').activeSubtitleId, '3');
    expect(merge(sid: '3', aid: '1').activeAudioId, '1');
    expect(merge(sid: 'no', aid: 'auto').activeSubtitleId, isNull);
    expect(merge(sid: 'no', aid: 'auto').activeAudioId, isNull);
    // Selected through media_kit, mpv not yet observed: its report stands.
    const picked = Track(
      audio: AudioTrack('2', null, null),
      subtitle: SubtitleTrack('3', null, null),
    );
    expect(merge(selected: picked).activeAudioId, '2');
    expect(merge(selected: picked).activeSubtitleId, '3');
    expect(merge(selected: picked, sid: 'no').activeSubtitleId, isNull);
  });

  test('an external file is reported by its URL, whoever selected it', () {
    expect(merge(sid: '4').activeSubtitleId, 'https://subs.example/fre.srt');
    final viaMediaKit = merge(
      selected: Track(
        subtitle: SubtitleTrack.uri(
          'https://subs.example/fre.srt',
          title: 'https://subs.example/fre.srt',
        ),
      ),
    );
    expect(viaMediaKit.activeSubtitleId, 'https://subs.example/fre.srt');
    // A track mpv knows that the list has not caught up with yet.
    expect(merge(sid: '9').activeSubtitleId, '9');
  });

  test('hardwareDecoding maps to the controller\'s hardware acceleration', () {
    expect(
      MediaKitEngine.configurationFor(hardwareDecoding: true)
          .enableHardwareAcceleration,
      isTrue,
    );
    final software = MediaKitEngine.configurationFor(hardwareDecoding: false);
    expect(software.enableHardwareAcceleration, isFalse);
    // Nothing else strays from media_kit's defaults.
    expect(software.vo, const VideoControllerConfiguration().vo);
    expect(software.hwdec, const VideoControllerConfiguration().hwdec);
  });
}
