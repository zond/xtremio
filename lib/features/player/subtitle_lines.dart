import 'dart:async';
import 'dart:math' show sqrt;

import 'package:flutter/material.dart';

/// The subtitle text over a film on the surface ([VideoOutput.surface]).
///
/// media_kit's own `SubtitleView` draws it for a film on the texture, and it
/// needs media_kit's `VideoController`, which the surface does not use. This
/// draws it the same way: mpv's current lines ([lines], from
/// `Player.stream.subtitle`), trimmed and joined, at the bottom centre, with
/// the padding animated over [duration] as `SubtitleView.setPadding` does,
/// and scaled to the space the same way (see [scaleFor]). A text subtitle on
/// either output looks the same.
class SubtitleLines extends StatefulWidget {
  const SubtitleLines({
    super.key,
    required this.lines,
    required this.initial,
    required this.style,
    required this.padding,
    this.duration = const Duration(milliseconds: 100),
  });

  final Stream<List<String>> lines;

  /// What is on screen when the widget is built, before [lines] says more.
  final List<String> initial;

  final TextStyle style;
  final EdgeInsets padding;
  final Duration duration;

  /// media_kit's text scale: the square root of the share of a 1920x1080
  /// screen the subtitles have, never above one.
  static double scaleFor(Size size) =>
      sqrt((size.width * size.height / (1920 * 1080)).clamp(0.0, 1.0));

  /// The text drawn for [lines]: each non-blank line trimmed, one per row.
  static String textFor(List<String> lines) => [
    for (final line in lines)
      if (line.trim().isNotEmpty) line.trim(),
  ].join('\n');

  @override
  State<SubtitleLines> createState() => _SubtitleLinesState();
}

class _SubtitleLinesState extends State<SubtitleLines> {
  late List<String> _lines = widget.initial;
  StreamSubscription<List<String>>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.lines.listen((lines) {
      if (mounted) setState(() => _lines = lines);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Material(
      color: Colors.transparent,
      child: AnimatedContainer(
        padding: widget.padding,
        duration: widget.duration,
        alignment: Alignment.bottomCenter,
        child: Text(
          SubtitleLines.textFor(_lines),
          style: widget.style,
          textAlign: TextAlign.center,
          textScaler: TextScaler.linear(
            SubtitleLines.scaleFor(constraints.biggest),
          ),
        ),
      ),
    ),
  );
}
