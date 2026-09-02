/// `m:ss`, or `h:mm:ss` from an hour up; negative durations get a leading
/// `-` (the "time remaining" display).
String formatTime(Duration duration) {
  final negative = duration.isNegative;
  final total = duration.abs().inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  final body = hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '$minutes:${two(seconds)}';
  return negative ? '-$body' : body;
}
