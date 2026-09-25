/// Finishing a Google Drive pairing, somewhere that is not a screen.
///
/// **Why this is not on the pairing screen any more.** The service holds a
/// finished pairing for about ten minutes and hands it over exactly once, to
/// whoever asks for it. While the only thing that asked was the screen the
/// viewer had started from, backing out of that screen threw the pairing
/// away — a Google sign-in, a consent, and every file they had picked, gone
/// with no error anywhere because nothing had failed. That happened three
/// times in one afternoon before it was understood.
///
/// So the work is the *account's*, which outlives any widget: the credential
/// and the file list were always going to be, and the screen was only ever
/// the thing that happened to start it. Backing out now stops being
/// destructive, which is the whole point — a spinner that means "this is
/// still happening" rather than "you must stay here".
///
/// **And the id is written down.** A job in memory survives a screen; it
/// does not survive the process being killed. The session id alone is enough
/// to collect a pairing that already reached the service, so it is kept in
/// the preferences and tried again on the next library — see
/// `PrefsClient.drivePendingSessionKey`. The one thing that cannot be
/// recovered is a process that died *between* the picking and the handover,
/// because the one-time code goes with it; that window is a second wide,
/// against the ten minutes that were being lost.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'diagnostics_log.dart';
import 'drive_account.dart';
import 'drive_pairing.dart';

/// How a pairing ended, for whoever is still watching.
enum DrivePairingJobOutcome {
  /// The files are in the account.
  linked,

  /// The credential arrived but the store would not keep it, so it is good
  /// for this run and gone after a restart. Worth saying out loud; it is the
  /// one outcome a viewer has to know about *later*.
  thisRunOnly,

  /// The session is not there any more: collected already, or expired. A
  /// fresh code is the way on.
  gone,

  /// Google or the service refused. Also a fresh code, and worth a sentence.
  refused,

  /// Nothing was reached. Worth trying again; nothing has been spent.
  unreachable,
}

/// One pairing being finished, owned by [DriveAccount].
///
/// A [ChangeNotifier] rather than a `Future` handed to a screen: several
/// things may want to know (the screen that started it, the library that
/// resumed it), and none of them owns it.
class DrivePairingJob extends ChangeNotifier {
  DrivePairingJob({required this.account, required this.service});

  final DriveAccount account;
  final DrivePairingService service;

  /// The session being finished, or null when nothing is in flight.
  String? get sessionId => _sessionId;
  String? _sessionId;

  /// What the last one came to, or null while one is running.
  DrivePairingJobOutcome? get outcome => _outcome;
  DrivePairingJobOutcome? _outcome;

  bool get running => _sessionId != null;

  /// Hands a native pick over and collects what it becomes.
  ///
  /// Returns when it is done, but **nothing has to wait for it**: the job
  /// notifies, and a screen that has gone away simply is not listening any
  /// more. Two of these never run at once — a second call while one is in
  /// flight is dropped, because the collecting read is destructive and two
  /// of them would turn one pairing into one pairing and one `404`.
  /// What these lines are written under: `drive`, beside the app's
  /// `images`, `player` and `boot`. In logcat that reads as
  /// `xtremio_core::app: drive: …`.
  ///
  /// **What is never in them.** No refresh token, no access token, no
  /// server auth code -- not their values and not their lengths. A session
  /// id *is* written: it is a uuid the service invented, useless without a
  /// pairing waiting behind it, and it is the one thing that makes a log
  /// line join up with a row in the service's records. Every pairing fault
  /// in this app so far was diagnosed by matching those two, and doing it
  /// without these lines took an hour each time.
  static const String target = 'drive';

  Future<void> finish({
    required String sessionId,
    required String serverAuthCode,
    required List<String> fileIds,
  }) async {
    if (running) {
      DiagnosticsLog.info(target, 'pairing: already finishing $_sessionId');
      return;
    }
    DiagnosticsLog.info(
      target,
      'pairing: handing over ${fileIds.length} files on $sessionId',
    );
    _start(sessionId);
    final handover = await service.handOverNativePick(
      sessionId: sessionId,
      serverAuthCode: serverAuthCode,
      fileIds: fileIds,
    );
    DiagnosticsLog.info(
      target,
      'pairing: handover $sessionId -> ${handover.name}',
    );
    if (handover != DrivePairingHandover.taken) {
      return _end(switch (handover) {
        DrivePairingHandover.gone => DrivePairingJobOutcome.gone,
        DrivePairingHandover.refused => DrivePairingJobOutcome.refused,
        _ => DrivePairingJobOutcome.unreachable,
      });
    }
    await _collect(sessionId);
  }

  /// Collects a pairing that reached the service and was never taken: the
  /// one a killed process leaves behind. Nothing is handed over here — that
  /// already happened — so all this needs is the id.
  Future<void> resume(String sessionId) async {
    if (running) return;
    // Bounded, because the thing that asks is woken by this job finishing:
    // a collect that keeps failing would otherwise wake the library, which
    // would ask again, for ever. Three goes is enough for a blip and short
    // of a loop, and a fourth comes with the next start of the app -- the
    // id is still written down.
    final tries = _tries[sessionId] ?? 0;
    if (tries >= maxTries) {
      DiagnosticsLog.info(
        target,
        'pairing: giving up on $sessionId for this run after $tries tries',
      );
      return;
    }
    DiagnosticsLog.info(
      target,
      'pairing: collecting what was left behind on $sessionId',
    );
    _tries[sessionId] = tries + 1;
    _start(sessionId);
    await _collect(sessionId);
  }

  /// How many times one outstanding pairing is asked for in a run.
  static const int maxTries = 3;

  final Map<String, int> _tries = {};

  Future<void> _collect(String sessionId) async {
    final answer = await service.collect(sessionId);
    DiagnosticsLog.info(
      target,
      'pairing: collect $sessionId -> ${answer.runtimeType}',
    );
    switch (answer) {
      case DrivePairingCollected():
        // One statement, from the answer into the account. The token is in
        // no field of this object and in no line of the log.
        final stored = await account.linkFiles(
          refreshToken: answer.refreshToken,
          files: answer.files,
        );
        _end(
          stored == DriveLinkOutcome.thisRunOnly
              ? DrivePairingJobOutcome.thisRunOnly
              : DrivePairingJobOutcome.linked,
        );
      case DrivePairingExpired():
      case DrivePairingGone():
        _end(DrivePairingJobOutcome.gone);
      case DrivePairingUnreachable():
        // The session is still there and still ready, so the id is *kept*:
        // this is exactly the case the written-down id exists for, and the
        // next library will try it again.
        _end(DrivePairingJobOutcome.unreachable, forget: false);
      case DrivePairingWaiting():
        // The service has the session but it is not ready: the handover has
        // not landed yet. Not a verdict, so the id is kept and the next
        // library asks again.
        _end(DrivePairingJobOutcome.unreachable, forget: false);
    }
  }

  void _start(String sessionId) {
    _sessionId = sessionId;
    _outcome = null;
    // Written down *before* the work, not after: the whole point is to
    // survive a process that stops in the middle of it.
    unawaited(account.prefs.setDrivePendingSession(sessionId));
    notifyListeners();
    _wakeAccount();
  }

  /// Wakes everything that depends on the account, **after** whatever is
  /// running now.
  ///
  /// A microtask and not a call: the thing that starts a resume is the
  /// library building, and an account that notified from inside that build
  /// would be marking its own dependents dirty mid-frame. The wake is not
  /// urgent -- it only has to happen before anybody could look again.
  void _wakeAccount() => scheduleMicrotask(account.notePairingChanged);

  void _end(DrivePairingJobOutcome outcome, {bool forget = true}) {
    DiagnosticsLog.info(
      target,
      'pairing: $_sessionId finished ${outcome.name}'
      '${forget ? '' : ', still outstanding'}',
    );
    _sessionId = null;
    _outcome = outcome;
    if (forget) unawaited(account.prefs.setDrivePendingSession(null));
    notifyListeners();
    _wakeAccount();
  }
}
