import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/language_names.dart';
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

  test('languageName knows two- and three-letter codes, keeps the rest', () {
    expect(languageName('eng'), 'English');
    expect(languageName('en'), 'English');
    expect(languageName('EN-US'), 'English');
    expect(languageName('pob'), 'Portuguese (Brazil)');
    expect(languageName('zh-TW'), 'Chinese (Traditional)');
    expect(languageName('xx'), 'xx');
  });

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
    expect(
      style.copyWith(backgroundColor: const Color(0xAA000000)),
      isNot(style),
    );
    expect(style.copyWith(), style);
    expect(style.hasBackground, isFalse);
    expect(
      const SubtitleStyle(backgroundColor: Color(0x01000000)).hasBackground,
      isTrue,
    );
  });

  test('SubtitleStyle reads and writes stremio-core colour strings', () {
    expect(SubtitleStyle.parseRgbaHex('#FFFFFFFF'), const Color(0xFFFFFFFF));
    expect(SubtitleStyle.parseRgbaHex('#00000000'), const Color(0x00000000));
    expect(SubtitleStyle.parseRgbaHex('#FFEB3BAA'), const Color(0xAAFFEB3B));
    // subtitlesOutlineColor's default has no alpha byte: opaque.
    expect(SubtitleStyle.parseRgbaHex('#000000'), const Color(0xFF000000));
    expect(SubtitleStyle.parseRgbaHex('ffeb3bff'), const Color(0xFFFFEB3B));
    expect(SubtitleStyle.parseRgbaHex('#FFF'), isNull);
    expect(SubtitleStyle.parseRgbaHex('#GGGGGGGG'), isNull);
    expect(SubtitleStyle.parseRgbaHex(''), isNull);
    expect(SubtitleStyle.toRgbaHex(const Color(0xAAFFEB3B)), '#FFEB3BAA');
    expect(SubtitleStyle.toRgbaHex(const Color(0x00000000)), '#00000000');
    for (final hex in [
      ...SubtitleStyle.textColors.values,
      ...SubtitleStyle.backgroundColors.values,
    ]) {
      expect(SubtitleStyle.toRgbaHex(SubtitleStyle.parseRgbaHex(hex)!), hex);
    }
  });

  test('SubtitleStyle.fromSettings scales 32 px by subtitlesSize', () {
    expect(
      SubtitleStyle.fromSettings(
        const ProfileSettings({
          'subtitlesSize': 150,
          'subtitlesTextColor': '#FFEB3BFF',
          'subtitlesBackgroundColor': '#000000AA',
        }),
      ),
      const SubtitleStyle(
        fontSize: 48,
        color: Color(0xFFFFEB3B),
        backgroundColor: Color(0xAA000000),
      ),
    );
    // Unknown settings (ctx not pulled yet) and garbage fall back to the
    // engine's defaults.
    expect(
      SubtitleStyle.fromSettings(const ProfileSettings({})),
      const SubtitleStyle(),
    );
    expect(
      SubtitleStyle.fromSettings(
        const ProfileSettings({
          'subtitlesTextColor': 'red',
          'subtitlesBackgroundColor': 'none',
        }),
      ),
      const SubtitleStyle(),
    );
  });

  test('languageOptions are three-letter codes, one per name, by name', () {
    final codes = [for (final option in languageOptions) option.code];
    expect(codes, contains('eng'));
    expect(codes, contains('fre'), reason: 'the bibliographic code');
    expect(codes, isNot(contains('fra')));
    expect(codes, isNot(contains('en')));
    expect(codes, isNot(contains('und')));
    expect(codes.toSet().length, codes.length);
    final names = [for (final option in languageOptions) option.name];
    expect(names, [...names]..sort());
    expect(names.toSet().length, names.length);
  });
}
