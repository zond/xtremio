import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/core_time_reporter.dart';

/// What the core is told about a playback's time, on its own. The screen's
/// tests (player_core_progress_test, player_leaving_test,
/// player_duration_report_test) hold it end to end.
void main() {
  const minute = Duration(minutes: 1);
  const film = Duration(minutes: 90);

  ({CoreTimeReporter reporter, List<Map<String, dynamic>> sent}) make() {
    final sent = <Map<String, dynamic>>[];
    final reporter = CoreTimeReporter(
      dispatch: (CoreAction action) =>
          sent.add(action.action['args'] as Map<String, dynamic>),
      device: 'tv',
      interval: const Duration(seconds: 1),
    );
    return (reporter: reporter, sent: sent);
  }

  String name(Map<String, dynamic> args) => args['action'] as String;
  int? time(Map<String, dynamic> args) =>
      (args['args'] as Map<String, dynamic>?)?['time'] as int?;

  test('reports nothing before there is a stream', () {
    final r = make();
    r.reporter.time(minute, film);
    r.reporter.seek(minute, film);
    r.reporter.flush(minute, film);
    r.reporter.playing(true);
    expect(r.sent, isEmpty);
  });

  test('reports nothing before the length is known', () {
    final r = make()..reporter.newStream(Duration.zero);
    r.reporter.time(minute, Duration.zero);
    r.reporter.seek(minute, Duration.zero);
    expect(r.sent, isEmpty);
  });

  test('a position going forward is a TimeChanged, throttled', () {
    final r = make()..reporter.newStream(Duration.zero);
    r.reporter.time(minute, film);
    r.reporter.time(minute + const Duration(milliseconds: 500), film);
    r.reporter.time(minute + const Duration(seconds: 1), film);
    expect(r.sent.map(name), ['TimeChanged', 'TimeChanged']);
    expect(r.sent.first['args'], {
      'time': 60000,
      'duration': 5400000,
      'device': 'tv',
    });
  });

  test('a position behind the core\'s offset is a Seek', () {
    final r = make()..reporter.newStream(const Duration(minutes: 30));
    r.reporter.time(minute, film);
    expect(r.sent.map(name), ['Seek']);
    r.reporter.time(minute * 2, film);
    expect(r.sent.map(name), ['Seek', 'TimeChanged']);
  });

  test('a seek is said, and the next position is not throttled', () {
    final r = make()..reporter.newStream(Duration.zero);
    r.reporter.time(minute, film);
    r.reporter.seek(minute * 10, film);
    r.reporter.time(minute * 10 + const Duration(milliseconds: 200), film);
    expect(r.sent.map(name), ['TimeChanged', 'Seek', 'TimeChanged']);
    expect(r.sent.map(time), [60000, 600000, 600200]);
  });

  test('a seek before the length is known still lifts the throttle', () {
    final r = make()..reporter.newStream(Duration.zero);
    r.reporter.time(minute, film);
    r.reporter.seek(minute * 10, Duration.zero);
    r.reporter.time(minute + const Duration(milliseconds: 200), film);
    expect(r.sent.map(name), ['TimeChanged', 'TimeChanged']);
  });

  test('a flush reports the position whatever the throttle says', () {
    final r = make()..reporter.newStream(Duration.zero);
    r.reporter.time(minute, film);
    r.reporter.flush(minute + const Duration(milliseconds: 300), film);
    expect(r.sent.map(time), [60000, 60300]);
  });

  test('a video left before it started is reported at its start', () {
    final r = make()..reporter.newStream(const Duration(minutes: 30));
    r.reporter.flush(Duration.zero, Duration.zero);
    expect(r.sent, [
      {
        'action': 'TimeChanged',
        'args': {'time': 0, 'duration': 0, 'device': 'tv'},
      },
    ]);
    r.reporter.flush(Duration.zero, Duration.zero);
    expect(r.sent, hasLength(1), reason: 'once');
  });

  test('a video already reported is not flushed back to its start', () {
    final r = make()..reporter.newStream(Duration.zero);
    r.reporter.time(minute, film);
    r.reporter.flush(Duration.zero, Duration.zero);
    expect(r.sent.map(name), ['TimeChanged']);
  });

  test('a new stream starts unreported', () {
    final r = make()..reporter.newStream(Duration.zero);
    r.reporter.time(minute, film);
    r.reporter.newStream(Duration.zero);
    r.reporter.flush(Duration.zero, Duration.zero);
    expect(r.sent.map(time), [60000, 0]);
  });

  test('playing is said once per change', () {
    final r = make()..reporter.newStream(Duration.zero);
    r.reporter.playing(true);
    r.reporter.playing(true);
    r.reporter.playing(false);
    expect(r.sent, [
      {
        'action': 'PausedChanged',
        'args': {'paused': false},
      },
      {
        'action': 'PausedChanged',
        'args': {'paused': true},
      },
    ]);
  });
}
