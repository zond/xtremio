/// Keeping the device's faces and the account's the same set.
///
/// The faces are the device's first (`AppPrefs.faces`): a press writes there
/// and the screen answers at once, signed in or not. This copies them to the
/// account on xtremio-xervice (`PUT /faces`, which merges) and takes back what
/// the account holds, so a title liked on the phone is liked on the television.
/// It runs on every change, and whenever the app finds itself signed in: at
/// start and at a sign-in.
///
/// **A first sync adds, it never replaces.** The service merges what is sent
/// into what it has, newest per title. A title only the device has marked
/// survives, and so does one only the account has ([Faces.merged] here,
/// `mergeFaces` there). The one thing that removes a mark another device still
/// holds is [forgetEverywhere]. It stamps the account's `clearedAt`, and every
/// mark older than that is dropped wherever it is merged next.
///
/// **Only the signed-in account's marks, and nobody's.** Marks are kept per
/// account on the device ([FacesByAccount]). A sync sends the account's own and
/// the ones made signed out. Those then become the account's, once: they leave
/// nobody's set as the answer lands. Another account's marks on this device are
/// never sent.
///
/// Signed out or offline is a sync that did not happen, quietly
/// ([XerviceIdentity]); the next change or the next start tries again.
library;

import 'dart:async';

import 'diagnostics_log.dart';
import 'faces.dart';
import 'prefs_client.dart';
import 'xervice_identity.dart';

class FacesSync {
  FacesSync({
    required this.prefs,
    required this.identity,
    this.now = DateTime.now,
  });

  final AppPrefs prefs;
  final XerviceIdentity identity;

  /// The clock a mark is stamped with.
  final DateTime Function() now;

  Future<void>? _running;
  bool _again = false;

  /// Marks [id] with [face] (null takes the mark off) on this device, and
  /// sends the set to the account.
  Future<void> setFace(String id, Face? face) async {
    await prefs.markFace(id, face, now());
    await sync();
  }

  /// Sends the device's set and keeps what the account answers merged into
  /// it. One at a time: a sync asked for while one is out runs once more
  /// after it, with whatever was marked meanwhile.
  Future<void> sync() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _once();
    } while (_again);
  }

  Future<void> _once() async {
    final owner = prefs.facesOwner;
    if (owner == null || !identity.signedIn) return;
    final nobodys = prefs.facesByAccount.of(null);
    final sent = prefs.facesByAccount.of(owner).merged(nobodys);
    final answer = await identity.send('PUT', '/faces', body: sent.toJson());
    if (answer == null) return;
    if (!answer.ok) {
      DiagnosticsLog.info('faces', 'not synced (${answer.status})');
      return;
    }
    // Written to [owner]'s set even if another account signed in while the
    // request was out: the answer is [owner]'s, and so is the set.
    // Merged with the set as it is now, not as it was sent: a press while
    // the request was out is newer than anything in the answer.
    await prefs.setFacesOf(
      owner,
      prefs.facesByAccount.of(owner).merged(Faces.fromJson(answer.json)),
    );
    // Nobody's marks are the account's now; the ones that were sent leave.
    final left = prefs.facesByAccount.of(null);
    await prefs.setFacesOf(
      null,
      Faces({
        for (final MapEntry(:key, :value) in left.marks.entries)
          if (nobodys.marks[key] != value) key: value,
      }),
    );
  }

  /// Forgets every face on the account and on this device. Answers whether the
  /// account heard it. Offline or signed out, nothing is forgotten anywhere, so
  /// the viewer is not told it was.
  Future<bool> forgetEverywhere() async {
    final owner = prefs.facesOwner;
    if (owner == null) return false;
    final answer = await identity.send('DELETE', '/faces');
    if (answer == null || !answer.ok) return false;
    await prefs.setFacesOf(owner, Faces.fromJson(answer.json));
    // The ones made signed out would be this account's at the next sync.
    await prefs.setFacesOf(null, Faces.empty);
    return true;
  }
}
