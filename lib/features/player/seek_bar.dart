import 'package:flutter/material.dart';

import 'time_format.dart';

/// The seek bar: buffered range, progress and a thumb over a thin track.
///
/// Dragging scrubs a local value and shows a time bubble; the engine is
/// only asked to seek on release ([onSeek]), so a long drag does not flood
/// libmpv with seeks. A plain tap seeks at once.
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.position,
    required this.buffered,
    required this.duration,
    required this.onSeek,
    this.onScrubStart,
    this.onScrubEnd,
  });

  final Duration position;
  final Duration buffered;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final VoidCallback? onScrubStart;
  final VoidCallback? onScrubEnd;

  static const double height = 28;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  /// Fraction under the pointer while dragging; null otherwise.
  double? _drag;
  bool _hover = false;

  bool get _enabled => widget.duration > Duration.zero;

  double _fraction(Duration value) {
    if (!_enabled) return 0;
    return (value.inMilliseconds / widget.duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
  }

  Duration _at(double fraction) => Duration(
    milliseconds: (widget.duration.inMilliseconds * fraction).round(),
  );

  double _fractionAt(Offset local, double width) =>
      (local.dx / width).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final drag = _drag;
        final progress = drag ?? _fraction(widget.position);
        return MouseRegion(
          cursor: _enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _enabled
                ? (details) => widget.onSeek(
                    _at(_fractionAt(details.localPosition, width)),
                  )
                : null,
            onHorizontalDragStart: _enabled
                ? (details) {
                    widget.onScrubStart?.call();
                    setState(
                      () => _drag = _fractionAt(details.localPosition, width),
                    );
                  }
                : null,
            onHorizontalDragUpdate: _enabled
                ? (details) => setState(
                    () => _drag = _fractionAt(details.localPosition, width),
                  )
                : null,
            onHorizontalDragEnd: _enabled ? (_) => _endDrag() : null,
            onHorizontalDragCancel: _enabled ? _endDrag : null,
            child: SizedBox(
              height: SeekBar.height,
              width: double.infinity,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _SeekBarPainter(
                        progress: progress,
                        buffered: _fraction(widget.buffered),
                        active: drag != null || _hover,
                        color: scheme.primary,
                        bufferColor: Colors.white.withValues(alpha: 0.45),
                        trackColor: Colors.white.withValues(alpha: 0.25),
                      ),
                    ),
                  ),
                  if (drag != null)
                    Positioned(
                      left: (drag * width - 32).clamp(0.0, width - 64),
                      bottom: SeekBar.height + 4,
                      child: _TimeBubble(time: _at(drag)),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _endDrag() {
    final drag = _drag;
    setState(() => _drag = null);
    if (drag != null) widget.onSeek(_at(drag));
    widget.onScrubEnd?.call();
  }
}

class _TimeBubble extends StatelessWidget {
  const _TimeBubble({required this.time});

  final Duration time;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        formatTime(time),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: Colors.white),
      ),
    );
  }
}

class _SeekBarPainter extends CustomPainter {
  const _SeekBarPainter({
    required this.progress,
    required this.buffered,
    required this.active,
    required this.color,
    required this.bufferColor,
    required this.trackColor,
  });

  final double progress;
  final double buffered;
  final bool active;
  final Color color;
  final Color bufferColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final thickness = active ? 6.0 : 4.0;
    final centerY = size.height / 2;
    final radius = Radius.circular(thickness / 2);
    RRect bar(double fraction) => RRect.fromRectAndRadius(
      Rect.fromLTWH(
        0,
        centerY - thickness / 2,
        size.width * fraction,
        thickness,
      ),
      radius,
    );
    canvas.drawRRect(bar(1), Paint()..color = trackColor);
    if (buffered > 0) {
      canvas.drawRRect(bar(buffered), Paint()..color = bufferColor);
    }
    if (progress > 0) canvas.drawRRect(bar(progress), Paint()..color = color);
    canvas.drawCircle(
      Offset(size.width * progress, centerY),
      active ? 8 : 6,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_SeekBarPainter old) =>
      old.progress != progress ||
      old.buffered != buffered ||
      old.active != active ||
      old.color != color;
}
