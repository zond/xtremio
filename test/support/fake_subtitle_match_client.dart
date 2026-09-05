import 'package:xtremio/features/player/subtitle_match.dart';

/// A [SubtitleMatchClient] that answers what a test told it to, and
/// records what it was asked.
///
/// Nothing in `test/features` reaches FFI, and this is the one the player
/// gets through `PlaybackScope`.
class FakeSubtitleMatchClient implements SubtitleMatchClient {
  /// What the next [match] answers. A test that wants a refusal answers
  /// one with `convincing: false` -- the Rust side reports a bad score
  /// rather than raising, and the player has to say so rather than treat
  /// it as an error.
  SubtitleMatch? response;

  /// Thrown instead of answering, for the file that cannot be read.
  Object? error;

  /// Completes each call, so a test can hold a measurement open and
  /// assert what the panel says while it runs. Null answers at once.
  Future<void>? pending;

  /// Every pair it was asked about, in order.
  final List<(Uri, Uri)> calls = [];

  @override
  Future<SubtitleMatch> match({
    required Uri playing,
    required Uri reference,
  }) async {
    calls.add((playing, reference));
    await pending;
    final error = this.error;
    if (error != null) throw error;
    return response!;
  }
}
