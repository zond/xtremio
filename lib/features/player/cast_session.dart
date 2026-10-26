import '../cast/cast_client.dart';
import '../cast/cast_compatibility.dart';

/// What a direct cast falls back on if the receiver refuses the link: the
/// session it was handed in, to be handed again through the LAN listener.
typedef CastDirectRetry = ({
  CastDevice device,
  CastDevice receiver,
  Uri local,
  CastCompatibility compatibility,
});

/// A cast on a receiver, from the hand-over until it ends.
///
/// The player screen holds one while a receiver has the stream and none
/// otherwise, so nothing here outlives the cast it was about. Not the cast's
/// clock and buffering count, which the screen keeps across a direct cast
/// handed again through this device: that is the same cast.
final class CastSession {
  CastSession({
    required this.device,
    required this.status,
    required this.handedAt,
    required this.video,
    required this.sent,
    required this.directRetry,
  }) : direct = directRetry != null;

  /// The receiver the stream was handed to.
  final CastDevice device;

  /// What the receiver last said, as it is believed ([trusted]).
  CastStatus status;

  /// What the remote says under the title while the receiver has reached
  /// this device and been sent nothing yet; null otherwise. A note and not
  /// an ending: a stream that is not here yet is waited for.
  String? note;

  /// The receiver has reported the media finished and the core has been
  /// told. A receiver keeps saying so; the core hears it once.
  bool ended = false;

  /// Where the receiver was told to start.
  final Duration handedAt;

  bool _reported = false;

  /// The picture the receiver was handed, for the check that it shows one:
  /// its codec as judged. Null for sound alone, which has none to show, and
  /// once the check has acted.
  String? video;

  /// How the film was sent, for the sentence that says it showed no picture.
  final String sent;

  /// Whether the receiver has reported a picture since the hand-over.
  bool pictureSeen = false;

  /// Where the receiver was when it first said it was playing.
  Duration? playingFrom;

  /// **The receiver fetches the stream from its source itself**: it was
  /// handed the link, not a token on the LAN listener. Nothing is served
  /// from this device for it -- no listener, no publication, no fetch
  /// watchdog -- and the remote says so.
  final bool direct;

  /// What a direct cast falls back on if the receiver refuses the link
  /// before it has played any of it. Null once the receiver has played (a
  /// later error is the film's, not the link's), after the fallback, and for
  /// a relayed cast.
  CastDirectRetry? directRetry;

  /// [reported], as far as it can be believed.
  ///
  /// The Cast SDK reports status and position on two streams. The client
  /// folds them together with the last position it saw, which before the
  /// receiver's first tick is a zero it never reported. Taken at its word,
  /// that zero reaches the core as `TimeChanged{0}` and is where local
  /// playback resumes if the session ends. So until the first tick the
  /// handed-over position stands in.
  CastStatus trusted(CastStatus reported) {
    if (_reported) return reported;
    if (reported.position != Duration.zero) {
      _reported = true;
      return reported;
    }
    return reported.at(handedAt);
  }
}
