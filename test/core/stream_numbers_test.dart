import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

/// The wire shape `stream_numbers.rs` serializes, parsed back. Every case
/// here is one of the server's own documented absences: it sends `null`
/// rather than leaving a key out, and each `null` means "there is no such
/// number", never zero.
void main() {
  test('reads a torrent that is holding, committed and moving', () {
    final numbers = StreamNumbers.fromJson(const {
      'window': {'behindBytes': 1288490188, 'aheadBytes': 356515840},
      'sharing': {
        'committedBytes': 859832320,
        'transfer': {
          'downloadedBytes': 4800,
          'uploadedBytes': 2100,
          'ratio': 0.4375,
        },
      },
    });
    expect(numbers, isNotNull);
    expect(numbers!.window?.behindBytes, 1288490188);
    expect(numbers.window?.aheadBytes, 356515840);
    expect(numbers.sharing?.committedBytes, 859832320);
    expect(numbers.sharing?.transfer?.downloadedBytes, 4800);
    expect(numbers.sharing?.transfer?.uploadedBytes, 2100);
    expect(numbers.sharing?.transfer?.ratio, 0.4375);
    expect(numbers.isEmpty, isFalse);
  });

  test('a proxied stream has a window and no sharing', () {
    final numbers = StreamNumbers.fromJson(const {
      'window': {'behindBytes': 60000000, 'aheadBytes': 30000000},
      'sharing': null,
    });
    expect(numbers?.window?.aheadBytes, 30000000);
    expect(numbers?.sharing, isNull);
  });

  test('a stream nothing is bounding has no window', () {
    final numbers = StreamNumbers.fromJson(const {
      'window': null,
      'sharing': {'committedBytes': null, 'transfer': null},
    });
    expect(numbers?.window, isNull);
    // A sharing with neither half is no sharing row, exactly as the server
    // says: the whole object would draw nothing.
    expect(numbers?.sharing, isNull);
    expect(numbers?.isEmpty, isTrue);
  });

  test('counters that cannot be read are absent, never three zeroes', () {
    final numbers = StreamNumbers.fromJson(const {
      'window': null,
      'sharing': {'committedBytes': 820, 'transfer': null},
    });
    expect(numbers?.sharing?.committedBytes, 820);
    expect(numbers?.sharing?.transfer, isNull);
  });

  test('half a transfer is no transfer, the way the server sends it', () {
    // The three travel as one group because they stand or fall together;
    // a byte count this build cannot read leaves the other one meaning
    // nothing, and a zero in its place would say the session moved none.
    final numbers = StreamNumbers.fromJson(const {
      'window': null,
      'sharing': {
        'committedBytes': null,
        'transfer': {'uploadedBytes': 2100, 'ratio': null},
      },
    });
    expect(numbers?.sharing, isNull);
  });

  test('a ratio against nothing downloaded comes back absent', () {
    final numbers = StreamNumbers.fromJson(const {
      'window': null,
      'sharing': {
        'committedBytes': null,
        'transfer': {
          'downloadedBytes': 0,
          'uploadedBytes': 2100,
          'ratio': null,
        },
      },
    });
    final transfer = numbers?.sharing?.transfer;
    expect(transfer?.uploadedBytes, 2100);
    expect(transfer?.ratio, isNull);
  });

  test(
    'the null the server sends for a stream it does not hold is no rows',
    () {
      expect(StreamNumbers.fromJson(null), isNull);
      // And so is anything this build cannot read: a shape it does not know
      // says nothing about the stream, which is what no rows means.
      expect(StreamNumbers.fromJson('nonsense'), isNull);
      expect(
        StreamNumbers.fromJson(const {'window': 'nonsense'})?.window,
        isNull,
      );
      expect(
        StreamNumbers.fromJson(const {
          'window': {'behindBytes': 12},
        })?.window,
        isNull,
        reason:
            'half a window is not a window: a zero on the other side would '
            'say the cache holds nothing there',
      );
    },
  );
}
