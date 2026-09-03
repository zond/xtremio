import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/well_formed_text.dart';

/// The two halves of `👤` (U+1F464), which is what a torrent addon writes
/// into a description and what a truncation upstream cuts through.
const String highHalf = '\uD83D';
const String lowHalf = '\uDC64';

void main() {
  group('well-formed text', () {
    test('leaves a string with nothing to fix exactly as it is', () {
      const plain = 'Alpha 1080p WEB-DL';
      expect(wellFormedText(plain), same(plain));
      const withEmoji = 'Torrentio\n👤 42 💾 1.51 GB';
      expect(wellFormedText(withEmoji), same(withEmoji));
      expect(wellFormedText(null), isNull);
      expect(wellFormedText(''), '');
    });

    test('drops a surrogate that has lost its other half', () {
      // The high half alone, at the end and in the middle.
      expect(wellFormedText('Alpha $highHalf'), 'Alpha ');
      expect(wellFormedText('Alpha ${highHalf}1080p'), 'Alpha 1080p');
      // The low half alone.
      expect(wellFormedText('Alpha $lowHalf 1080p'), 'Alpha  1080p');
      // Half of one pair between two whole ones: only the half goes.
      expect(wellFormedText('👤$highHalf💾'), '👤💾');
    });

    test('what is left is a string the text engine will take', () {
      final broken = 'Torrentio $highHalf 42 💾';
      final fixed = wellFormedText(broken)!;
      for (var i = 0; i < fixed.length; i++) {
        final unit = fixed.codeUnitAt(i);
        if (unit >= 0xD800 && unit <= 0xDBFF) {
          expect(
            fixed.codeUnitAt(i + 1),
            inInclusiveRange(0xDC00, 0xDFFF),
            reason: 'a high surrogate kept its low half',
          );
          i++;
        } else {
          expect(unit, isNot(inInclusiveRange(0xDC00, 0xDFFF)));
        }
      }
      // And the emoji that was whole is still whole and still one
      // character, not two halves that happen to have survived.
      expect(fixed.runes.length, fixed.characters.length);
      expect(fixed.contains('💾'), isTrue);
    });
  });
}
