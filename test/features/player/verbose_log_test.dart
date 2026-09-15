import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:xtremio/features/player/playback_engine.dart';

/// What "Verbose diagnostics" changes about a player, decided before the
/// player exists so it can be checked without one: the log level mpv is
/// asked for, the `msg-level` override, and which lines reach the engine
/// log.
void main() {
  test('mpv is asked for info-level log only under verbose diagnostics', () {
    expect(
      MediaKitEngine.playerConfigurationFor(verboseLog: false).logLevel,
      MPVLogLevel.error,
    );
    expect(
      MediaKitEngine.playerConfigurationFor(verboseLog: true).logLevel,
      MPVLogLevel.info,
    );
  });

  test(
    'msg-level is set only under verbose diagnostics, on top of the rest',
    () {
      final quiet = MediaKitEngine.overridesFor(verboseLog: false);
      final verbose = MediaKitEngine.overridesFor(verboseLog: true);
      expect(quiet.containsKey('msg-level'), isFalse);
      expect(
        verbose['msg-level'],
        MediaKitEngine.verboseMpvOverrides['msg-level'],
      );
      for (final MapEntry(:key, :value)
          in MediaKitEngine.mpvOverrides.entries) {
        expect(quiet[key], value);
        expect(verbose[key], value);
      }
    },
  );

  test('errors always reach the engine log; demux, stream and cache only '
      'under verbose diagnostics; nothing else ever', () {
    bool carries(String prefix, String level, {required bool verbose}) =>
        MediaKitEngine.engineLogCarries(
          prefix: prefix,
          level: level,
          verboseLog: verbose,
        );
    expect(carries('vo/gpu', 'error', verbose: false), isTrue);
    expect(carries('vo/gpu', 'error', verbose: true), isTrue);
    for (final prefix in ['demux', 'stream', 'cache']) {
      expect(carries(prefix, 'info', verbose: false), isFalse, reason: prefix);
      expect(carries(prefix, 'info', verbose: true), isTrue, reason: prefix);
    }
    expect(carries('cplayer', 'info', verbose: true), isFalse);
    expect(carries('vo/gpu', 'v', verbose: true), isFalse);
  });
}
