/// Where the subtitle auto-pick stands for the media on screen.
///
/// The auto-pick puts the viewer's subtitle up without being asked, and
/// upgrades it as better files arrive from the addons. Four things decide
/// whether it may look again, and they are not one state: a pick can be in
/// flight while an earlier one stands at its rank, and the viewer can choose
/// by hand while a pick is in flight. So they are kept apart here, and each
/// change has a name.
///
/// One per media: the screen replaces it when a new stream opens. A pick
/// in flight keeps the one it began with, so its answer cannot touch the
/// next media's.
class SubtitleAutoPick {
  int? _rank;
  bool _settled = false;
  bool _applying = false;
  bool _byHand = false;

  /// How good the subtitle the auto-pick put on screen is; null while it
  /// has put nothing there. A candidate has to beat this to replace it.
  int? get rank => _rank;

  /// Whether the viewer has said what they want of the subtitles for this
  /// media: picked a file, an embedded track or none, or moved the timing by
  /// hand. That leaves the auto-pick nothing to guess at.
  bool get byHand => _byHand;

  /// Whether the auto-pick may look again now: it has not settled, no pick
  /// is in flight, and the viewer has not chosen.
  bool get mayPick => !_settled && !_applying && !_byHand;

  /// The viewer chose. Nothing the auto-pick does from here changes that.
  void chooseByHand() => _byHand = true;

  /// What is on screen is the best there will be: every subtitle addon has
  /// answered and nothing better came. Only once something is on screen.
  void settle() {
    if (_rank != null) _settled = true;
  }

  /// A pick went to the engine and has not been answered yet.
  void applying() => _applying = true;

  /// The engine took the pick, of [rank]. With [settles], it is as good as
  /// it gets, or nothing better is coming.
  ///
  /// Only an engine's acceptance is recorded, so an engine that keeps
  /// refusing a pick leaves the auto-pick free to try again, which is why
  /// [byHand] is a gate of its own.
  void accepted(int rank, {required bool settles}) {
    _rank = rank;
    if (settles) _settled = true;
  }

  /// The engine has answered the pick in flight, either way.
  void answered() => _applying = false;

  /// The file the auto-pick put up could not be loaded, and [rankBefore]'s
  /// went back on screen. A candidate now has to beat that, and the pick is
  /// open again, past the dead file.
  void refused(int? rankBefore) {
    _rank = rankBefore;
    _settled = false;
  }
}
