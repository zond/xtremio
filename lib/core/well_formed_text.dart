/// Making addon text safe to lay out.
///
/// A Dart `String` is a sequence of UTF-16 code units, and a code unit in
/// `D800..DFFF` is only half a character: the two halves of a surrogate
/// pair spell one code point above the BMP, which is where the emoji
/// torrent addons write into their names and descriptions live (`👤`
/// U+1F464, `💾` U+1F4BE). Flutter's text layout refuses a string holding
/// half of such a pair — `ArgumentError: string is not well-formed UTF-16`
/// out of `ParagraphBuilder.addText` — and refusing to lay out is not a
/// small failure: it throws where the row is built, so the release name
/// renders as `<?>` and the log fills with the same line a hundred times
/// over.
///
/// Nothing in this app cuts a string in half — a row title is handed whole
/// to a `Text` with `maxLines` and `TextOverflow.ellipsis`, which shortens
/// the *painted* line and never the string, and every parser here is a
/// regex over the whole text. So a half character can only arrive already
/// broken: an addon whose JSON carries a lone `\uD83D` (a title truncated
/// on its side, a bad transcoding upstream) is a string `jsonDecode`
/// accepts and the text engine will not draw.
///
/// [wellFormedText] is the guard at that door. It is deliberately at the
/// boundary where addon text becomes *display* text and nowhere else: the
/// raw stream JSON `Load Player` takes back is never touched, because what
/// goes to the engine should be what the addon said.
library;

/// [text] with every unpaired surrogate dropped: a half character is not
/// something to render, and it is not something a viewer can be shown as
/// anything but damage.
///
/// A well-paired surrogate — every emoji an addon writes — is left exactly
/// as it is, and so is the string object itself when there is nothing to
/// fix, which is nearly always: this runs on every stream row.
String? wellFormedText(String? text) {
  if (text == null || !_hasBrokenSurrogate(text)) return text;
  final kept = <int>[];
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (_isHighSurrogate(unit)) {
      // A high surrogate is a character only with its low half next to it;
      // both go in together, or the half goes.
      if (i + 1 < text.length && _isLowSurrogate(text.codeUnitAt(i + 1))) {
        kept.add(unit);
        kept.add(text.codeUnitAt(++i));
      }
      continue;
    }
    // A low surrogate reached here has no high half before it (one that
    // did was consumed above), so it is a half character too.
    if (_isLowSurrogate(unit)) continue;
    kept.add(unit);
  }
  return String.fromCharCodes(kept);
}

/// Whether [text] holds a surrogate that is not part of a pair. Separate
/// from the repair so the common answer costs one scan and no allocation.
bool _hasBrokenSurrogate(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (_isHighSurrogate(unit)) {
      if (i + 1 < text.length && _isLowSurrogate(text.codeUnitAt(i + 1))) {
        i++;
        continue;
      }
      return true;
    }
    if (_isLowSurrogate(unit)) return true;
  }
  return false;
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
