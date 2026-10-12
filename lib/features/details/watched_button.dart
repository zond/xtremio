import 'package:flutter/material.dart';

/// Whether a film is watched, and the way to say it is or is not: a check
/// beside the bookmark on the details page, before the faces.
///
/// Films only. A series' watched state is which episodes, and its episode
/// list is where that is seen and changed.
///
/// Drawn the way the faces are ([IconButton.filled], `face_buttons.dart`):
/// unwatched an outlined check, watched a filled check on the accent disc.
/// Pressing it sends stremio-core's `MetaItemMarkAsWatched` with the other
/// value, which also works for a film the library has never seen (it makes
/// the temporary item a finished playback would).
abstract final class WatchedButton {
  static const String markTooltip = 'Mark as watched';
  static const String watchedTooltip = 'Watched, press to clear';

  /// The button. [focusNode] is for a television, where the ring is put on
  /// by hand around it.
  static Widget of({
    required bool watched,
    required ValueChanged<bool> onWatched,
    FocusNode? focusNode,
  }) => IconButton.filled(
    focusNode: focusNode,
    tooltip: watched ? watchedTooltip : markTooltip,
    isSelected: watched,
    icon: const Icon(Icons.check_circle_outline),
    selectedIcon: const Icon(Icons.check_circle),
    onPressed: () => onWatched(!watched),
  );
}
