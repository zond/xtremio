import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

/// The wire vocabulary the streaming server and the app share: what
/// `?buffer=` says, and what putting it on a stream URL must not disturb.
void main() {
  group('the wire spelling', () {
    test('is what the server takes, and what is stored', () {
      expect(BufferAhead.normal.wire, 'normal');
      expect(BufferAhead.large.wire, 'large');
      expect(BufferAhead.maximum.wire, 'maximum');
      // The whole-file option is not a fourth window: it is the widest one
      // the server has, plus a pin. The server knows nothing of it.
      expect(BufferAhead.wholeFile.wire, 'maximum');
      expect(BufferAhead.wholeFile.stored, 'wholeFile');
      expect(BufferAhead.wholeFile.storesTheFile, isTrue);
      expect(BufferAhead.maximum.storesTheFile, isFalse);
    });

    test('round-trips through what is stored', () {
      for (final choice in BufferAhead.values) {
        expect(BufferAhead.parse(choice.stored), choice);
      }
    });

    test('an unknown value is not a choice', () {
      // A name a newer build wrote, or a file this one cannot make sense
      // of, reads as "nothing set" -- which is the default, not a failure.
      for (final stored in ['', 'huge', 'Normal', 4, null, true]) {
        expect(BufferAhead.parse(stored), isNull, reason: '$stored');
      }
    });
  });
}
