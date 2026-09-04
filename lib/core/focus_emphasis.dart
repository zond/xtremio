/// How strongly the thing the remote is on is marked, on a television.
///
/// The indicator has to read over poster art on a display the app knows
/// nothing about: a projector in a room with the curtains open washes the
/// picture out, and a coloured line over a busy poster is the first thing
/// to go. [standard] answers that without being asked -- two strokes of
/// opposite luminance, and a zoom that does not depend on contrast at all.
///
/// [bold] is for the room where that is still not enough. It cannot be the
/// default: dimming everything the remote is *not* on is the strongest cue
/// available, and far too heavy for a dark room.
///
/// A television box has no light sensor to decide this from, which is
/// exactly why it is a setting.
library;

enum FocusEmphasis {
  /// The default: a double-stroke ring, a slight zoom and a shadow.
  standard,

  /// A thicker ring, and everything that is not focused dimmed.
  bold;

  /// What the setting is stored as (`AppPrefs.focusEmphasisKey`).
  String get stored => name;

  /// The choice in plain words.
  String get label => switch (this) {
    FocusEmphasis.standard => 'Standard',
    FocusEmphasis.bold => 'Bold',
  };

  /// One line on what it does, on the tile rather than in a help page.
  String get description => switch (this) {
    FocusEmphasis.standard =>
      'Outlines what is focused in black and white, and zooms it a little.',
    FocusEmphasis.bold =>
      'Thickens that outline and dims everything else. For a bright room.',
  };

  /// The stored spelling back to a choice; null for anything else,
  /// including a name a newer build wrote, so an unknown value reads as
  /// "not set" rather than as a failure.
  static FocusEmphasis? parse(Object? stored) {
    if (stored is! String) return null;
    for (final choice in FocusEmphasis.values) {
      if (choice.stored == stored) return choice;
    }
    return null;
  }
}
