import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/core.dart';

/// What the stats panel's cache and sharing rows read: what the server
/// holds of the stream on screen, asked every [interval] while the screen
/// wants it ([run]).
///
/// **[numbers] is a reading and nothing else**: set only from an answer
/// about the stream on screen now, and dropped the moment nothing polls it
/// ([stop]), so the past is never shown as the present. It notifies when
/// [numbers] changes.
class StreamNumbersPoll extends ChangeNotifier {
  StreamNumbersPoll({
    required this.reader,
    required this.interval,
    required this.target,
  });

  /// Where the numbers come from; none in a build with no server.
  final StreamNumbersReader? Function() reader;

  final Duration interval;

  /// What to ask about now: the stream's media id, or else the URL the
  /// server serves it at, and the stream on screen they belong to. An answer
  /// is kept only while the same stream is.
  final ({String? id, Uri? url, Object? stream}) Function() target;

  Timer? _timer;
  bool _fetching = false;
  StreamNumbers? _numbers;
  bool _disposed = false;

  /// The last reading, while one is being taken.
  StreamNumbers? get numbers => _numbers;

  /// Asks every [interval], starting now: whoever just opened the panel
  /// wants the numbers at once. Already running, it carries on.
  void run() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => poll());
    poll();
  }

  /// Stops asking and forgets the last reading, which are one act. A
  /// reading describes the moment it was taken. Kept past its poll, it would
  /// come back on screen (the panel reopened, the app brought forward, the
  /// next video started) as a reading of something it was never taken from.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _numbers = null;
  }

  /// One ask, about what [target] names now, and nothing when it names
  /// nothing. It is decided per ask, because what the engine was handed can
  /// change under an open panel (a re-open for a new buffer window).
  ///
  /// An answer that comes back after the stream changed, or after the
  /// polling stopped, is not kept. Every failure is no reading: the server
  /// not running and a stream it does not hold both mean there is nothing to
  /// draw.
  Future<void> poll() async {
    final (:id, :url, :stream) = target();
    final reader = this.reader();
    if ((id == null && url == null) || reader == null || _fetching) return;
    _fetching = true;
    StreamNumbers? numbers;
    try {
      numbers = id != null
          ? await reader.mediaStreamNumbers(id)
          : await reader.streamNumbers(url!);
    } on Object {
      numbers = null;
    } finally {
      _fetching = false;
    }
    if (_disposed || _timer == null || target().stream != stream) return;
    if (numbers?.isEmpty ?? false) numbers = null;
    if (numbers == _numbers) return;
    _numbers = numbers;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
