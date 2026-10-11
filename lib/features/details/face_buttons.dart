import 'package:flutter/material.dart';

import '../../core/faces.dart';

/// The happy face and the sad one, beside the bookmark: what the viewer
/// thought of a title, for the For you row.
///
/// At rest both are drawn, unfilled. Pressing one marks the title: that
/// face is drawn filled in the accent colour and the other goes, so what
/// is left says what was said. Pressing it again takes the mark off and
/// both come back. [onFace] is told the face the title should have now,
/// null for none. A title dismissed from For you shows both, unfilled;
/// liking it replaces the dismissal.
abstract final class FaceButtons {
  static const String likeTooltip = 'I liked this';
  static const String likedTooltip = 'Liked, press to clear';
  static const String dislikeTooltip = 'Not for me';
  static const String dislikedTooltip = 'Disliked, press to clear';

  /// Whether the happy face is drawn: unless the title is disliked.
  static bool showsLike(Face? current) => current != Face.dislike;

  /// Whether the sad face is drawn: unless the title is liked.
  static bool showsDislike(Face? current) => current != Face.like;

  /// What pressing [pressed] while the title has [current] leaves it with.
  static Face? after(Face? current, Face pressed) =>
      current == pressed ? null : pressed;

  /// The happy face's button. [focusNode] is for a television, where the
  /// ring is put on by hand around it.
  static Widget like({
    required Face? current,
    required ValueChanged<Face?> onFace,
    FocusNode? focusNode,
  }) {
    final on = current == Face.like;
    return IconButton(
      focusNode: focusNode,
      tooltip: on ? likedTooltip : likeTooltip,
      isSelected: on,
      icon: const Icon(Icons.sentiment_satisfied_outlined),
      selectedIcon: const Icon(Icons.sentiment_satisfied),
      onPressed: () => onFace(after(current, Face.like)),
    );
  }

  /// The sad face's button.
  static Widget dislike({
    required Face? current,
    required ValueChanged<Face?> onFace,
    FocusNode? focusNode,
  }) {
    final on = current == Face.dislike;
    return IconButton(
      focusNode: focusNode,
      tooltip: on ? dislikedTooltip : dislikeTooltip,
      isSelected: on,
      icon: const Icon(Icons.sentiment_dissatisfied_outlined),
      selectedIcon: const Icon(Icons.sentiment_dissatisfied),
      onPressed: () => onFace(after(current, Face.dislike)),
    );
  }
}
