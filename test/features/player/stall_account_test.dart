import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/stall_account.dart';

import '../../support/diagnostics_capture.dart';

/// A playback's stalls on their own. player_stall_report_test holds what
/// reaches the server end to end.
void main() {
  const step = Duration(milliseconds: 500);

  ({StallAccount account, void Function(Duration) advance}) make() {
    var now = DateTime(2026, 10, 26);
    return (
      account: StallAccount(now: () => now),
      advance: (by) => now = now.add(by),
    );
  }

  test('counts once two seconds of film have played since the open', () {
    final a = make().account..opened();
    for (var i = 0; i < 3; i++) {
      a.moved(step);
    }
    expect(a.counts, isFalse);
    a.moved(step);
    expect(a.counts, isTrue);
  });

  test('a seek starts the count over', () {
    final a = make().account..opened();
    for (var i = 0; i < 4; i++) {
      a.moved(step);
    }
    a.seeked();
    expect(a.counts, isFalse);
  });

  test('a step back or a jump forward is a seek whoever made it', () {
    final a = make().account..opened();
    for (var i = 0; i < 3; i++) {
      a.moved(step);
    }
    a.moved(-step);
    a.moved(step);
    expect(a.counts, isFalse, reason: 'the frames of a scrub back');
    for (var i = 0; i < 4; i++) {
      a.moved(step);
    }
    expect(a.counts, isTrue);
    a.moved(StallAccount.playbackTick);
    expect(a.counts, isFalse);
  });

  test('a new open starts from nothing', () {
    final a = make().account..opened();
    for (var i = 0; i < 4; i++) {
      a.moved(step);
    }
    a.opened();
    expect(a.counts, isFalse);
  });

  test('says how long ago the open was', () {
    final m = make();
    expect(m.account.sinceOpened, isNull);
    m.account.opened();
    m.advance(const Duration(milliseconds: 1234));
    expect(m.account.sinceOpened, const Duration(milliseconds: 1234));
  });

  test('logs the first ten stalls, then every tenth', () {
    final lines = captureDiagnostics();
    final m = make();
    m.account.opened();
    for (var i = 1; i <= 20; i++) {
      m.account.buffering(true, at: Duration(seconds: i));
      m.advance(const Duration(milliseconds: 40));
      m.account.buffering(false, at: Duration(seconds: i));
    }
    final stalls = lines.where((l) => l.contains('stalled at')).toList();
    expect(stalls, hasLength(11));
    expect(stalls.first, contains('stalled at 1s (stall 1)'));
    expect(stalls.last, contains('stalled at 20s (stall 20)'));
    final again = lines.where((l) => l.contains('playing again after'));
    expect(again, hasLength(11));
    expect(again.first, contains('playing again after 40ms'));
  });

  test('the end of a stall that never began is not logged', () {
    final lines = captureDiagnostics();
    make().account.buffering(false, at: Duration.zero);
    expect(lines.where((l) => l.contains('playing again')), isEmpty);
  });
}
