import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'idle_sharing.dart';

/// What the embedded server is giving to the swarm at one moment: the rate
/// bytes are leaving at, how many bytes have left in total, and how many
/// torrents they are leaving from.
///
/// It is a reading, not a claim: everything here is what the server answered
/// when it was last asked, and nothing derives from the setting. A viewer
/// who has turned sharing on but is not uploading anything reads exactly the
/// same as one who has turned it off, which is the whole point of measuring
/// rather than reporting the switch.
@immutable
final class SharingActivity {
  const SharingActivity({
    this.uploadSpeed = 0,
    this.uploadedBytes = 0,
    this.torrents = 0,
  });

  /// Bytes per second going out, over every torrent the server holds.
  final double uploadSpeed;

  /// Bytes that have gone out since the server started, over the same
  /// torrents. Cumulative, so two readings apart in time say whether
  /// anything really left the device in between -- which is a measurement,
  /// where [uploadSpeed] alone is a sample that can read zero in the gap
  /// between two pieces.
  final int uploadedBytes;

  /// How many torrents are being uploaded from.
  final int torrents;

  /// Nothing is known, which is also what nothing going out looks like.
  /// The two are deliberately one value: a light that cannot tell them
  /// apart stays off for both, and off is the answer that claims nothing.
  static const SharingActivity none = SharingActivity();

  @override
  bool operator ==(Object other) =>
      other is SharingActivity &&
      other.uploadSpeed == uploadSpeed &&
      other.uploadedBytes == uploadedBytes &&
      other.torrents == torrents;

  @override
  int get hashCode => Object.hash(uploadSpeed, uploadedBytes, torrents);

  @override
  String toString() =>
      'SharingActivity($uploadSpeed B/s, $uploadedBytes B, $torrents torrents)';
}

/// Asks the embedded server what it is uploading right now.
///
/// **There is no implementation of this over the pinned server, and that is
/// a fact about the server rather than an omission here.** What would answer
/// it exists and is already computed: `GET /stats.json` reports every live
/// engine's `uploadSpeed`/`uploaded` (`routes::system::combined_engine_stats`,
/// which merges `EngineFS::get_all_statistics` over the stream engine and the
/// download engine). What the app may use is the *library* API over FFI --
/// the app never speaks HTTP to the embedded server -- and `ServerHandle`
/// exposes no all-engines call: it has `engine_stats(info_hash, trackers)`
/// and `file_stats(...)`, both per torrent.
///
/// **Those two must not stand in for it.** A stats request for a hash with
/// no engine *creates* one (`routes::system::stats_target` falls through to
/// `get_or_begin_add_magnet`), so polling the last film's hash to find out
/// whether it is still being shared would re-add the torrent the server had
/// already swept -- the icon would start the very sharing it exists to
/// report. Approximating with `AppPrefs.shareWhileIdle` is the other way to
/// get this wrong: a light that is on whenever the setting is on says
/// nothing and becomes furniture.
///
/// So the smallest honest addition is one method on `ServerHandle` returning
/// `combined_engine_stats` (the parity rule that server keeps between its
/// routes and its library API), and a `server_sharing_activity` FFI function
/// here summing it into the three numbers above. Until that lands the app
/// builds no client, [SharingActivityMonitor] never polls, and the light is
/// never drawn -- which is the honest state, not a broken one.
abstract interface class SharingActivityClient {
  /// One reading. Throws when the server is not running or refuses.
  Future<SharingActivity> fetch();
}

/// Polls a [SharingActivityClient] while somebody is watching, and says
/// whether bytes are actually going out.
///
/// One of these for the whole app, built by `XtremioApp` beside
/// [IdleSharingPolicy], because there is one server to ask.
///
/// **It polls only while [watching].** The shell turns it on while its own
/// route is on top and off as soon as anything is pushed over it, so nothing
/// is asked while a film is playing -- which is also when the answer would
/// be true and would mean something else entirely, since a torrent being
/// streamed uploads to the swarm as it goes.
///
/// **What it reports is what moved.** [uploading] is true when the last two
/// readings show bytes having left the device, and falls back to the rate
/// for the first reading of a run, which has nothing to compare against. The
/// rate alone is a sample: librqbit reports it over a short window, so a
/// seeding torrent between two pieces can read zero and blink a light that
/// nothing is wrong with. A counter that grew cannot.
///
/// **A failure is darkness, not the last answer.** An error means the app
/// does not know, and a light that stays on when nothing is known is a claim
/// it cannot support.
class SharingActivityMonitor extends ChangeNotifier {
  SharingActivityMonitor({
    required this.client,
    this.period = const Duration(seconds: 5),
  });

  /// Where the readings come from, or null when nothing can answer -- see
  /// [SharingActivityClient], which is the state the app ships in today.
  final SharingActivityClient? client;

  /// How often the server is asked while [watching]. Five seconds: the
  /// thing being watched lives for minutes (an idle engine is swept after
  /// five of them), so this is fast enough to catch the start and the end
  /// of a share, and slow enough that it costs the bridge nothing.
  final Duration period;

  SharingActivity _activity = SharingActivity.none;

  /// The last reading, or [SharingActivity.none] when there is none.
  SharingActivity get activity => _activity;

  bool _uploading = false;

  /// Bytes are going out right now; see the class comment for what that is
  /// measured from.
  bool get uploading => _uploading;

  Timer? _timer;

  /// [SharingActivity.uploadedBytes] of the reading before this one, so the
  /// comparison above has something to make. Null until a run has taken a
  /// reading at all, which is what makes the first one fall back to the
  /// rate.
  int? _lastUploaded;

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
      _forget();
      return;
    }
    if (client == null) return;
    _timer = Timer.periodic(period, (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  Future<void> _poll() async {
    final client = this.client;
    if (client == null) return;
    final SharingActivity reading;
    try {
      reading = await client.fetch();
    } catch (error) {
      // The server may not be up, or may be shutting down. Not knowing is
      // not the same as knowing nothing is going out, but it is drawn the
      // same way: nothing.
      if (kDebugMode) debugPrint('sharing activity unavailable: $error');
      _forget();
      return;
    }
    // A reading that arrived after the watch stopped belongs to nobody.
    if (!watching) return;
    final before = _lastUploaded;
    _lastUploaded = reading.uploadedBytes;
    _update(
      reading,
      uploading: before == null
          ? reading.uploadSpeed > 0
          : reading.uploadedBytes > before,
    );
  }

  void _forget() {
    _lastUploaded = null;
    _update(SharingActivity.none, uploading: false);
  }

  void _update(SharingActivity reading, {required bool uploading}) {
    if (reading == _activity && uploading == _uploading) return;
    _activity = reading;
    _uploading = uploading;
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
/// field: it notifies nobody, and what reads it -- the light's popup and the
/// settings tile -- is built afresh each time it is looked at.
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
