import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/cast/cast_client.dart';
import 'package:xtremio/features/cast/cast_compatibility.dart';
import 'package:xtremio/features/player/cast_session.dart';

/// A cast on a receiver, on its own. What the remote and the core make of
/// it is held by player_cast_test and player_direct_cast_test.
void main() {
  const device = CastDevice(id: 'tv', name: 'Living Room TV');
  const handedAt = Duration(minutes: 37);

  CastSession session({CastDirectRetry? retry}) => CastSession(
    device: device,
    status: const CastStatus(state: CastPlayerState.buffering),
    handedAt: handedAt,
    video: 'h264',
    sent: 'the film as it is',
    directRetry: retry,
  );

  test('a zero before the first tick is the hand-over position', () {
    final s = session();
    const zero = CastStatus(state: CastPlayerState.buffering);
    expect(s.trusted(zero).position, handedAt);
  });

  test('the first position of its own is believed, and every one after', () {
    final s = session();
    const moved = CastStatus(
      state: CastPlayerState.playing,
      position: Duration(minutes: 37, seconds: 1),
    );
    expect(s.trusted(moved).position, moved.position);
    const zero = CastStatus(state: CastPlayerState.playing);
    expect(s.trusted(zero).position, Duration.zero);
  });

  test('a cast handed the link is direct, and one relayed is not', () {
    final retry = (
      device: device,
      receiver: device,
      local: Uri.parse('xtremio://m1'),
      compatibility: const CastReady(contentType: 'video/mp4'),
    );
    expect(session(retry: retry).direct, isTrue);
    expect(session().direct, isFalse);
  });

  test('a direct cast stays direct once its fallback is spent', () {
    final s = session(
      retry: (
        device: device,
        receiver: device,
        local: Uri.parse('xtremio://m1'),
        compatibility: const CastReady(contentType: 'video/mp4'),
      ),
    )..directRetry = null;
    expect(s.direct, isTrue);
  });
}
