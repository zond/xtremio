/// Talking to the pairing service in `drive-link/`: opening a session and
/// collecting what a phone left on it.
///
/// The service is the half of a Google Drive pairing that needs a client
/// secret, which a sideloaded app cannot hold: it turns an authorization
/// code into tokens and a refresh token into an access token. What this
/// file does is the television's two calls -- `POST /session` for something
/// to draw, and `GET /session/{id}` until the phone has finished -- and
/// nothing else. Its README has the whole flow.
///
/// **The collecting call is destructive**, which is the one thing a caller
/// has to build around: the service deletes the session in the same request
/// that hands the tokens over, so a second read of a session that answered
/// [DrivePairingCollected] is a `404` and the credential is gone for good.
/// So a [DrivePairingCollected] is never dropped, never retried and never
/// asked for twice -- see `DrivePairingScreen`, which is the only caller.
///
/// **Neither token is written down here.** The refresh token is carried in
/// one field of one object, straight from the response into
/// [DriveAccount.linkFile], and nothing in this file logs a body, a header
/// or an answer; [DrivePairingCollected.toString] names the file and not
/// the credential, because a `$answer` in a debug line is the commonest way
/// a secret gets filed (`AGENTS.md`, "Never log auth material"). The access
/// token the same answer carries is **not read at all**: it is good for an
/// hour, this device has nowhere safe to put a second credential, and
/// `DriveSource` in the streaming server mints its own from the refresh
/// token through `POST /refresh` when it wants one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A session the service has opened: what to draw, and what to poll.
@immutable
final class DrivePairingSession {
  const DrivePairingSession({
    required this.sessionId,
    required this.code,
    required this.link,
    required this.expiresAt,
  });

  /// The session's own id, which is what [DrivePairingService.collect] is
  /// called with. Not drawn: it is a UUID, and a UUID is not something a
  /// viewer reads off a television or types into a phone.
  final String sessionId;

  /// Six characters out of an alphabet with no `I`, `O`, `0` or `1` in it,
  /// minted by the service for a camera that will not read the QR.
  ///
  /// **No route on the service consumes it yet.** It is stored on the
  /// session and returned here, and nothing reads it back -- so what the
  /// screen can honestly do with it is show it, which is what it does. A
  /// page that asked for it is the service's half of this fallback and is
  /// not written; pointing a viewer at one would be a lie drawn a metre
  /// high.
  final String code;

  /// The URL the QR carries and the phone opens: `/link?s=<sessionId>`.
  final String link;

  /// When the service says it will stop answering for this session, in UTC.
  ///
  /// Read as a *length* and never compared against the clock: a television's
  /// own time is whatever DHCP handed it and is routinely wrong by hours,
  /// and a session believed expired the moment it opened is a screen nobody
  /// can use (`DriveSource` in the streaming server keeps its token's life
  /// as a duration for the same reason). See `DrivePairingScreen.windowOf`.
  final DateTime expiresAt;

  /// One session as the service describes it, or null when the answer is
  /// not one this build can use. Every field is needed: a session with no
  /// id cannot be collected, and one with no link has nothing to draw.
  static DrivePairingSession? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['sessionId'];
    final code = json['code'];
    final link = json['link'];
    final expiresAt = json['expiresAt'];
    if (id is! String || id.trim().isEmpty) return null;
    if (link is! String || link.trim().isEmpty) return null;
    final until = expiresAt is String ? DateTime.tryParse(expiresAt) : null;
    if (until == null) return null;
    return DrivePairingSession(
      sessionId: id.trim(),
      code: code is String ? code.trim() : '',
      link: link.trim(),
      expiresAt: until.toUtc(),
    );
  }

  @override
  String toString() => 'DrivePairingSession($code)';
}

/// What `POST /session` came back with.
sealed class DrivePairingOpening {
  const DrivePairingOpening();
}

/// A session to draw and to poll.
final class DrivePairingOpened extends DrivePairingOpening {
  const DrivePairingOpened(this.session);

  final DrivePairingSession session;
}

/// No session, and a sentence saying why that a viewer can act on: the
/// service is unreachable, or it is refusing to open more sessions for this
/// address this hour (`429`, sixty an hour, which is the cost limit the
/// service exists behind rather than anything about this device).
final class DrivePairingUnavailable extends DrivePairingOpening {
  const DrivePairingUnavailable(this.reason);

  /// Written here, whole, for a screen to draw as it stands. Never a body
  /// echoed back from the service: somebody else's text may contain
  /// anything that was sent to them.
  final String reason;

  @override
  String toString() => 'DrivePairingUnavailable($reason)';
}

/// What one `GET /session/{id}` came back with.
sealed class DrivePairingAnswer {
  const DrivePairingAnswer();
}

/// The phone has not finished. [signedIn] is the difference between "nobody
/// has scanned it yet" and "somebody is looking at their Drive", which is
/// the one thing a viewer waiting in front of a television wants told.
final class DrivePairingWaiting extends DrivePairingAnswer {
  const DrivePairingWaiting({required this.signedIn});

  final bool signedIn;
}

/// The pairing, collected. **The session no longer exists**: this object is
/// the only copy of the credential, so whatever happens next it is handed
/// to [DriveAccount] and not thrown away.
final class DrivePairingCollected extends DrivePairingAnswer {
  const DrivePairingCollected({
    required this.refreshToken,
    required this.fileId,
    required this.name,
    required this.mimeType,
  });

  /// The long-lived grant. **Never logged, never drawn, never put in a
  /// URL**: it does not expire on its own and it reaches every file the
  /// account has picked through this OAuth client. It goes from here into
  /// [DriveAccount.linkFile] and nowhere else.
  final String refreshToken;

  /// Drive's own id for the file the viewer picked -- the only field here
  /// that has to be right, since it is what a byte range is asked for.
  final String fileId;

  /// What the file is called in their Drive, for the list they are shown.
  final String name;

  /// What Drive says it is (`video/x-matroska`). Empty when the Picker sent
  /// none, which is no worse than a wrong one.
  final String mimeType;

  /// The file and never the token; see the library comment.
  @override
  String toString() => 'DrivePairingCollected($fileId)';
}

/// `410`: the ten minutes are up, and the service has dropped the session.
/// Nothing is retried past this -- a fresh code is the only way on.
final class DrivePairingExpired extends DrivePairingAnswer {
  const DrivePairingExpired();
}

/// `404`: there is no such session. Either the phone never finished and
/// Firestore's TTL collected it, or somebody else read it -- and a read is
/// a delete, so the pairing this screen was waiting for is not coming.
/// Terminal, like [DrivePairingExpired], and for the same reason.
final class DrivePairingGone extends DrivePairingAnswer {
  const DrivePairingGone();
}

/// Nothing came back, or something this build cannot read did.
///
/// **Not terminal.** A television drops off its wifi and comes back, and a
/// pairing that gave up on the first failed poll would be a pairing that
/// fails whenever the room's router is busy. The bound on retrying is the
/// session's own ten minutes, not a count of failures.
final class DrivePairingUnreachable extends DrivePairingAnswer {
  const DrivePairingUnreachable();
}

/// The television's side of the pairing service. An interface because the
/// screen that drives it is walked by a widget test with a remote, and a
/// test must not reach the network.
abstract interface class DrivePairingService {
  /// Asks for a session: `POST /session`.
  Future<DrivePairingOpening> open();

  /// Asks what has happened to [sessionId]: `GET /session/{id}`.
  ///
  /// **Deletes the session** when it answers [DrivePairingCollected]. Call
  /// it once per session at a time and never again after that answer.
  Future<DrivePairingAnswer> collect(String sessionId);
}

/// [DrivePairingService] over the deployed service.
class XtremioDrivePairingService implements DrivePairingService {
  const XtremioDrivePairingService({
    this.origin = defaultOrigin,
    this.timeout = const Duration(seconds: 15),
  });

  /// Where the service lives, as the service itself writes it down
  /// (`drive-link/functions/index.js`, `PUBLIC_ORIGIN`). It has to be this
  /// host and not the Cloud Run one behind the Hosting rewrite: the pages
  /// are served here, and this is the redirect URI the OAuth client knows.
  static const String defaultOrigin = 'https://xtremio-drive.web.app';

  final String origin;

  /// How long one call is given. Generous: this runs while a viewer is
  /// looking at a QR code, and a poll that timed out is one poll.
  final Duration timeout;

  @override
  Future<DrivePairingOpening> open() async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final answer = await _send(
        client,
        'POST',
        Uri.parse('$origin/session'),
      ).timeout(timeout);
      if (answer.statusCode == HttpStatus.tooManyRequests) {
        await answer.drain<void>();
        return const DrivePairingUnavailable(tooManyCodes);
      }
      final json = await _json(answer);
      if (answer.statusCode != HttpStatus.ok) {
        return const DrivePairingUnavailable(notReached);
      }
      final session = DrivePairingSession.fromJson(json);
      if (session == null) return const DrivePairingUnavailable(notUnderstood);
      return DrivePairingOpened(session);
    } on Object {
      // Every way a socket can fail is one sentence to a viewer, and the
      // exception's own text is not it: a DNS failure and a refused
      // connection are the same problem from an armchair.
      return const DrivePairingUnavailable(notReached);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<DrivePairingAnswer> collect(String sessionId) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final answer = await _send(
        client,
        'GET',
        Uri.parse('$origin/session/$sessionId'),
      ).timeout(timeout);
      switch (answer.statusCode) {
        case HttpStatus.gone:
          await answer.drain<void>();
          return const DrivePairingExpired();
        case HttpStatus.notFound:
          await answer.drain<void>();
          return const DrivePairingGone();
        case HttpStatus.ok:
          break;
        default:
          await answer.drain<void>();
          return const DrivePairingUnreachable();
      }
      return _readAnswer(await _json(answer));
    } on Object {
      return const DrivePairingUnreachable();
    } finally {
      client.close(force: true);
    }
  }

  /// What a `200` body means.
  ///
  /// `{"status": "pending"}` and `{"status": "signed-in"}` are the phone
  /// part-way through; `ready` carries the pairing and means the session
  /// has just been deleted. A body naming a status this build does not know
  /// is [DrivePairingUnreachable] and so is polled again -- a service that
  /// grew a fourth waiting state is not a pairing this screen should give
  /// up on.
  static DrivePairingAnswer _readAnswer(Map<String, dynamic>? json) {
    final status = json?['status'];
    if (status == 'pending') return const DrivePairingWaiting(signedIn: false);
    if (status == 'signed-in') {
      return const DrivePairingWaiting(signedIn: true);
    }
    if (status != 'ready') return const DrivePairingUnreachable();
    final token = json?['refreshToken'];
    final file = json?['file'];
    final fileId = file is Map ? file['fileId'] : null;
    if (token is! String || token.isEmpty) {
      // A `ready` with no grant on it is the one shape nothing can be
      // rescued from: the session is deleted either way, so there is
      // nothing left to poll for.
      return const DrivePairingGone();
    }
    if (fileId is! String || fileId.trim().isEmpty) {
      return const DrivePairingGone();
    }
    final name = file is Map ? file['name'] : null;
    final mimeType = file is Map ? file['mimeType'] : null;
    return DrivePairingCollected(
      refreshToken: token,
      fileId: fileId.trim(),
      name: name is String ? name : '',
      mimeType: mimeType is String ? mimeType : '',
    );
  }

  /// What a viewer is told when the service will not open a session.
  static const String notReached =
      'Could not reach the pairing service. '
      'Check this device is on the network and try again.';
  static const String tooManyCodes =
      'Too many codes have been asked for '
      'from this connection in the last hour. Try again shortly.';
  static const String notUnderstood =
      'The pairing service answered '
      'something this version does not understand.';

  static Future<HttpClientResponse> _send(
    HttpClient client,
    String method,
    Uri url,
  ) async {
    final request = await client.openUrl(method, url);
    // Nothing here follows a redirect: both routes answer JSON directly,
    // and the one redirect the service issues is the phone's.
    request.followRedirects = false;
    return request.close();
  }

  /// How much of a body this reads before calling it malformed. Every body
  /// it reads is a small JSON object.
  static const int _maxBodyBytes = 16 * 1024;

  static Future<Map<String, dynamic>?> _json(HttpClientResponse answer) async {
    final bytes = <int>[];
    var tooBig = false;
    await for (final chunk in answer) {
      // Read to the end even past the cap, so the connection is finished
      // with rather than abandoned half-read.
      if (tooBig) continue;
      bytes.addAll(chunk);
      tooBig = bytes.length > _maxBodyBytes;
    }
    if (tooBig) return null;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }
}
