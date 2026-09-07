import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fixtures.dart';

void main() {
  test('decodes what the server answers at start-up: everything dark', () {
    final traffic = BackgroundTraffic.fromJson(loadBackgroundTrafficFixture());
    expect(traffic.active, isFalse);
    expect(traffic.downloading, isFalse);
    expect(traffic.uploading, isFalse);
    expect(traffic.playing, isFalse);
    expect(traffic.bytesDownloaded, 0);
    expect(traffic.bytesUploaded, 0);
    expect(traffic.windowSecs, 5);
  });

  test('reads every field the wire carries, camelCase', () {
    final traffic = BackgroundTraffic.fromJson({
      'active': true,
      'downloading': false,
      'uploading': true,
      'playing': false,
      'bytesDownloaded': 1048576,
      'bytesUploaded': 4194304,
      'windowSecs': 5,
    });
    expect(traffic.active, isTrue);
    expect(traffic.downloading, isFalse);
    expect(traffic.uploading, isTrue);
    expect(traffic.playing, isFalse);
    expect(traffic.bytesDownloaded, 1048576);
    expect(traffic.bytesUploaded, 4194304);
    expect(traffic.windowSecs, 5);
  });

  test('a field the server did not answer reads dark, never lit', () {
    final traffic = BackgroundTraffic.fromJson(const {});
    expect(traffic.active, isFalse);
    expect(traffic.downloading, isFalse);
    expect(traffic.uploading, isFalse);
    expect(traffic.playing, isFalse);
    expect(traffic.bytesDownloaded, 0);
    expect(traffic.bytesUploaded, 0);
    expect(traffic.windowSecs, 0);
  });

  test('two readings compare by value, so a monitor can tell a change', () {
    final a = BackgroundTraffic.fromJson(loadBackgroundTrafficFixture());
    final b = BackgroundTraffic.fromJson(loadBackgroundTrafficFixture());
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    final lit = BackgroundTraffic.fromJson({
      ...loadBackgroundTrafficFixture(),
      'active': true,
      'uploading': true,
    });
    expect(lit, isNot(a));
  });
}
