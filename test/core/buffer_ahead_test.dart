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

  group('putting it on a stream URL', () {
    test('keeps every parameter the torrent URL already carried', () {
      final url = Uri.parse(
        'http://127.0.0.1:11470/abc/0'
        '?tr=udp%3A%2F%2Fone&tr=udp%3A%2F%2Ftwo&f=Episode+02',
      );

      final withBuffer = withBufferAhead(url, BufferAhead.large);

      expect(withBuffer.queryParametersAll['tr'], [
        'udp://one',
        'udp://two',
      ], reason: 'a tracker dropped is a tracker the engine never gets');
      expect(withBuffer.queryParametersAll['f'], ['Episode 02']);
      expect(withBuffer.queryParameters['buffer'], 'large');
      expect(withBuffer.path, '/abc/0');
    });

    test('replaces a buffer already there rather than repeating it', () {
      final url = Uri.parse('http://127.0.0.1:11470/abc/0?buffer=normal');
      final withBuffer = withBufferAhead(url, BufferAhead.maximum);
      expect(withBuffer.queryParametersAll['buffer'], ['maximum']);
    });

    test('an empty query contributes no empty pair', () {
      // stremio-core writes a bare `?` for a torrent with no trackers.
      final withBuffer = withBufferAhead(
        Uri.parse('http://127.0.0.1:11470/abc/0?'),
        BufferAhead.normal,
      );
      expect(withBuffer.query, 'buffer=normal');
    });
  });

  group('withPlayerToken', () {
    test('names the player and keeps every other parameter', () {
      final url = Uri.parse(
        'http://127.0.0.1:1/abc/0?tr=udp%3A%2F%2Fa&tr=udp%3A%2F%2Fb&buffer=normal',
      );
      final tagged = withPlayerToken(url, '5f3a9c0e1b2d4a67.3');
      expect(tagged.queryParameters['p'], '5f3a9c0e1b2d4a67.3');
      expect(tagged.queryParametersAll['tr'], ['udp://a', 'udp://b']);
      expect(tagged.queryParameters['buffer'], 'normal');
      expect(tagged.path, url.path);
    });

    test('replaces a token already there', () {
      final tagged = withPlayerToken(
        Uri.parse('http://127.0.0.1:1/abc/0?p=5f3a9c0e1b2d4a67.1'),
        '5f3a9c0e1b2d4a67.2',
      );
      expect(tagged.queryParametersAll['p'], ['5f3a9c0e1b2d4a67.2']);
    });
  });
}
