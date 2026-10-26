import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/player_status.dart';
import 'package:xtremio/features/player/torrent_stall_overlay.dart';

PlayerStatus? statusOf({
  String? engineError,
  bool loaded = true,
  String? unplayable,
  bool opened = true,
  bool waiting = false,
  bool torrent = false,
}) => PlayerStatus.of(
  engineError: engineError,
  loaded: loaded,
  unplayable: unplayable,
  opened: opened,
  waiting: waiting,
  torrent: torrent,
);

void main() {
  test('a film that plays has nothing to say', () {
    expect(statusOf(), isNull);
  });

  test("the engine's failure comes before everything else", () {
    final status = statusOf(
      engineError: 'no such file',
      loaded: false,
      unplayable: 'no URL',
      opened: false,
      waiting: true,
    );
    expect(status, isA<PlaybackFailed>());
    expect(status!.text, 'Playback failed: no such file');
    expect(status.failed, isTrue);
  });

  test('no stream yet is loading, whatever else is unknown', () {
    final status = statusOf(loaded: false, opened: false, waiting: true);
    expect(status, isA<PlayerLoading>());
    expect(status!.text, 'Loading…');
    expect(status.failed, isFalse);
  });

  test('an unplayable stream says why and stops trying', () {
    final status = statusOf(unplayable: 'no URL', opened: false);
    expect(status, isA<StreamUnplayable>());
    expect(status!.text, 'no URL');
    expect(status.failed, isTrue);
  });

  test('a stream not handed to the engine is opening, not buffering', () {
    final status = statusOf(opened: false, waiting: true);
    expect(status, isA<StreamOpening>());
    expect(status!.text, 'Opening the stream…');
    expect(status.failed, isFalse);
  });

  test("a wait is buffering, in the stall card's words for a torrent", () {
    final link = statusOf(waiting: true);
    expect(link, isA<PlayerWaiting>());
    expect(link!.text, 'Buffering…');
    expect(link.failed, isFalse);
    expect(
      statusOf(waiting: true, torrent: true)!.text,
      TorrentStallOverlay.waiting,
    );
  });
}
