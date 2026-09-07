import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/core.dart';
import 'idle_sharing.dart';

/// Asks the embedded server whether it is using this device's connection
/// while nothing is playing: one [BackgroundTraffic] per reading.
///
/// It is a reading, not a claim. Everything in the answer is what the
/// server measured -- per direction, whether librqbit's own peer counters
/// grew over the last window with no player reading over it -- and nothing
/// derives from the sharing setting. A viewer who has turned sharing on but
/// is moving no bytes reads exactly the same as one who has turned it off,
/// which is the whole point of measuring rather than reporting the switch.
///
/// **The per-torrent stats calls must not stand in for this.** A stats
/// request for a hash with no engine *creates* one
/// (`routes::system::stats_target` falls through to
/// `get_or_begin_add_magnet`), so polling the last film's hash to find out
/// whether it is still being shared would re-add the torrent the server had
/// already swept -- the light would start the very sharing it exists to
/// report. `ServerHandle::background_traffic` is the opposite kind of call:
/// it peeks at the counters of the engines that exist, creates nothing and
/// touches no idle clock, which is what makes it safe to poll.
abstract interface class SharingActivityClient {
  /// One reading. Throws when the server is not running or refuses.
  Future<BackgroundTraffic> fetch();
}

/// [SharingActivityClient] over FFI: [ServerClient.backgroundTraffic],
/// which is `server_background_traffic`. What the app ships with.
class RustSharingActivityClient implements SharingActivityClient {
  const RustSharingActivityClient({this.server = const ServerClient()});

  final ServerClient server;

  @override
  Future<BackgroundTraffic> fetch() => server.backgroundTraffic();
}

/// Polls a [SharingActivityClient] while somebody is watching, and says
/// whether bytes are moving in each direction.
///
/// One of these for the whole app, built by `XtremioApp` beside
/// [IdleSharingPolicy], because there is one server to ask.
///
/// **It polls only while [watching].** The shell turns it on while its own
/// route is on top and off as soon as anything is pushed over it, so nothing
/// is asked while a film is playing. The server folds "nothing playing" into
/// the answer itself, so this is not what keeps the light off during a
/// film; it is what keeps a light nobody can see from costing anything.
///
/// **What it reports is what the server judged, unchanged.** [uploading]
/// and [downloading] are the reading's own halves -- each "that direction's
/// counter grew over the last window and nothing was playing" -- and
/// [active] is either. The window is closed by whoever asks, so [period] is
/// its length: five seconds, the server's own `TRAFFIC_WINDOW`, long enough
/// to cover the gap between two block requests and short enough that the
/// answer is about now. Nothing is inferred here from a previous reading;
/// the comparison of two counters is the server's, made over one set of
/// torrents, and doing it again on this side would be a second judge.
///
/// **A failure is darkness, not the last answer.** An error means the app
/// does not know, and a light that stays on when nothing is known is a claim
/// it cannot support.
class SharingActivityMonitor extends ChangeNotifier {
  SharingActivityMonitor({
    required this.client,
    this.period = const Duration(seconds: 5),
  });

  /// Where the readings come from.
  final SharingActivityClient client;

  /// How often the server is asked while [watching], which is also the
  /// window each reading is judged over; see the class comment.
  final Duration period;

  BackgroundTraffic _reading = BackgroundTraffic.none;

  /// The last reading, or [BackgroundTraffic.none] when there is none.
  BackgroundTraffic get reading => _reading;

  /// Bytes went out to peers over the last window with nothing playing.
  bool get uploading => _reading.uploading;

  /// Bytes came in from peers over the last window with nothing playing.
  bool get downloading => _reading.downloading;

  /// Either: the connection is in use while nobody is watching. What the
  /// light is drawn from.
  bool get active => uploading || downloading;

  Timer? _timer;

  bool get watching => _timer != null;

  /// Starts or stops the polling. Idempotent, and starting takes a reading
  /// at once rather than waiting out the first [period].
  ///
  /// Stopping forgets what was read, because what it was is no longer known
  /// to be true: the next start asks again.
  set watching(bool value) {
    if (value == watching) return;
    if (!value) {
      _timer?.cancel();
      _timer = null;
      _update(BackgroundTraffic.none);
      return;
    }
    _timer = Timer.periodic(period, (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  Future<void> _poll() async {
    final BackgroundTraffic reading;
    try {
      reading = await client.fetch();
    } catch (error) {
      // The server may not be up, or may be shutting down. Not knowing is
      // not the same as knowing nothing is moving, but it is drawn the
      // same way: nothing.
      if (kDebugMode) debugPrint('sharing activity unavailable: $error');
      _update(BackgroundTraffic.none);
      return;
    }
    // A reading that arrived after the watch stopped belongs to nobody.
    if (!watching) return;
    _update(reading);
  }

  void _update(BackgroundTraffic reading) {
    if (reading == _reading) return;
    _reading = reading;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// The one [SharingActivityMonitor] and the one [IdleSharingPolicy], where
/// the shell can reach them.
///
/// An [InheritedNotifier] over the monitor, so anything drawing the light
/// is rebuilt when what the server is doing changes. The policy is a plain
/// field, and a [Listenable] of its own: this scope is not rebuilt when a
/// "Not now" is granted -- the same object goes on holding it -- so the
/// settings tile, which draws that pause and is on screen while the popup
/// granting it is open, listens to the policy rather than to this.
class SharingScope extends InheritedNotifier<SharingActivityMonitor> {
  const SharingScope({
    super.key,
    required this.policy,
    required SharingActivityMonitor monitor,
    required super.child,
  }) : super(notifier: monitor);

  final IdleSharingPolicy policy;

  /// The scope above [context], or null where there is none (a widget test
  /// that does not care about sharing). Depends on it: a widget reading
  /// this is rebuilt when the monitor changes its mind.
  static SharingScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SharingScope>();

  /// The same scope without depending on it, for a key handler and the
  /// other places that read outside a build.
  static SharingScope? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SharingScope>();

  SharingActivityMonitor get monitor => notifier!;
}
