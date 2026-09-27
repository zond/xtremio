import 'package:flutter/widgets.dart';

/// Whether [text] in [style] needs more than [maxLines] at [maxWidth], laid
/// out the way a [Text] in [context] would lay it out: its direction and its
/// text scale.
///
/// What decides whether a clamped description gets a way to see the rest.
bool textOverflows(
  BuildContext context,
  String text, {
  required TextStyle? style,
  required int maxLines,
  required double maxWidth,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: maxLines,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: maxWidth);
  final overflows = painter.didExceedMaxLines;
  painter.dispose();
  return overflows;
}
