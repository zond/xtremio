import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_shortcut.dart';

void main() {
  PlayerShortcut? plain(LogicalKeyboardKey key) =>
      PlayerShortcut.of(key, shift: false);
  PlayerShortcut? shifted(LogicalKeyboardKey key) =>
      PlayerShortcut.of(key, shift: true);

  test("mpv's and stremio-web's keys", () {
    expect(plain(LogicalKeyboardKey.space), PlayerShortcut.togglePlay);
    expect(plain(LogicalKeyboardKey.keyK), PlayerShortcut.togglePlay);
    expect(plain(LogicalKeyboardKey.keyJ), PlayerShortcut.seekBack);
    expect(plain(LogicalKeyboardKey.keyL), PlayerShortcut.seekForward);
    expect(plain(LogicalKeyboardKey.arrowLeft), PlayerShortcut.seekBack);
    expect(plain(LogicalKeyboardKey.arrowRight), PlayerShortcut.seekForward);
    expect(plain(LogicalKeyboardKey.arrowUp), PlayerShortcut.volumeUp);
    expect(plain(LogicalKeyboardKey.arrowDown), PlayerShortcut.volumeDown);
    expect(plain(LogicalKeyboardKey.keyM), PlayerShortcut.mute);
    expect(plain(LogicalKeyboardKey.keyF), PlayerShortcut.fullscreen);
    expect(plain(LogicalKeyboardKey.escape), PlayerShortcut.escape);
    expect(plain(LogicalKeyboardKey.keyS), PlayerShortcut.subtitles);
    expect(plain(LogicalKeyboardKey.keyA), PlayerShortcut.audio);
    expect(plain(LogicalKeyboardKey.keyN), PlayerShortcut.next);
  });

  test("a remote's media keys", () {
    expect(plain(LogicalKeyboardKey.mediaPlayPause), PlayerShortcut.togglePlay);
    expect(plain(LogicalKeyboardKey.mediaPlay), PlayerShortcut.play);
    expect(plain(LogicalKeyboardKey.mediaPause), PlayerShortcut.pause);
    expect(plain(LogicalKeyboardKey.mediaStop), PlayerShortcut.stop);
    expect(plain(LogicalKeyboardKey.mediaRewind), PlayerShortcut.seekBack);
    expect(
      plain(LogicalKeyboardKey.mediaFastForward),
      PlayerShortcut.seekForward,
    );
    expect(plain(LogicalKeyboardKey.mediaTrackNext), PlayerShortcut.next);
    expect(
      plain(LogicalKeyboardKey.mediaTrackPrevious),
      PlayerShortcut.restart,
    );
  });

  test('Shift makes four keys into others', () {
    expect(shifted(LogicalKeyboardKey.arrowLeft), PlayerShortcut.shortSeekBack);
    expect(
      shifted(LogicalKeyboardKey.arrowRight),
      PlayerShortcut.shortSeekForward,
    );
    expect(shifted(LogicalKeyboardKey.keyS), PlayerShortcut.subtitleTiming);
    expect(shifted(LogicalKeyboardKey.keyI), PlayerShortcut.stats);
  });

  test('Shift leaves every other key as it is', () {
    expect(shifted(LogicalKeyboardKey.space), PlayerShortcut.togglePlay);
    expect(shifted(LogicalKeyboardKey.arrowUp), PlayerShortcut.volumeUp);
    expect(shifted(LogicalKeyboardKey.keyN), PlayerShortcut.next);
  });

  test('I alone and keys the player has no use for mean nothing', () {
    expect(plain(LogicalKeyboardKey.keyI), isNull);
    expect(plain(LogicalKeyboardKey.keyQ), isNull);
    expect(shifted(LogicalKeyboardKey.keyQ), isNull);
  });

  test('only seeking and the volume act on a held key', () {
    expect(
      PlayerShortcut.values.where((shortcut) => shortcut.repeats).toSet(),
      {
        PlayerShortcut.seekBack,
        PlayerShortcut.seekForward,
        PlayerShortcut.shortSeekBack,
        PlayerShortcut.shortSeekForward,
        PlayerShortcut.volumeUp,
        PlayerShortcut.volumeDown,
      },
    );
  });
}
