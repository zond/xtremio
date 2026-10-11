import 'package:flutter/material.dart';

import '../../core/faces.dart';

/// The happy face and the sad one, beside the bookmark: what the viewer
/// thought of a title, for the For you row.
///
/// One replaces the other, and pressing the one that is on takes it off --
/// so [onFace] is told the face the title should have now, null for none.
/// A title dismissed from For you shows neither as on; liking it replaces
/// the dismissal.
abstract final class FaceButtons {
  static const String likeTooltip = 'I liked this';
  static const String likedTooltip = 'Liked: press to take it back';
  static const String dislikeTooltip = 'Not for me';
  static const String dislikedTooltip = 'Disliked: press to take it back';

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
