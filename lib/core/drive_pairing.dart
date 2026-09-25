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
/// [DriveAccount.linkFiles], and nothing in this file logs a body, a header
/// or an answer; [DrivePairingCollected.toString] names the files and not
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

/// Where the pick page sends a phone's browser when the picking is done, so
/// that a viewer this app handed to a browser is handed back to it.
///
/// **Nothing in this app acts on this link**, and that is the design rather
/// than an omission. `deepLinkAddonManifestUrl` drops a `stremio://` link
/// with no host -- those are the official clients' own in-app routes -- so
/// this arrives, means nothing, and is dropped. The whole effect of it is
/// the platform bringing this app to the front, which is what a hand-back
/// is. That is what answers the two objections written down against
/// `app_links` here (see `DrivePairingScreen`): the scheme keeps its one
/// meaning, "open that addon's details", because this adds no second one;
/// and a launch link the platform replays on a cold start days later is
/// dropped then too, because it was never acted on in the first place.
///
/// The end that actually sends it is the service, whose `HAND_BACK_LINK`
/// (`drive-link/functions/index.js`) is the copy that matters -- the URL is
/// hard-coded there so that a page on that origin never navigates to a URL
/// a client sent it. This constant is the app's side of the agreement and
/// nothing but a test reads it.
const String drivePairingHandBackLink = 'stremio:///pair';

/// The pairing session a link carries, or null when [link] is not one of
/// this app's pairing links.
///
/// **This is the second half of the QR, and the reason the phone can pick
/// more than one file.** The code a television draws is
/// `https://<origin>/link?s=<session>`, and it has always been a web page.
/// On a phone that has this app it is now an **App Link** instead: Android
/// verifies the app against `/.well-known/assetlinks.json` on that origin
/// and hands the URL here rather than to a browser. Same QR, same television
/// screen — a phone without the app still gets the page, which is why that
/// page stays.
///
/// It is worth being exact about why this is not the objection recorded in
/// `DrivePairingScreen`. That one was about `stremio://`, a scheme whose one
/// meaning is "open that addon's details" and which the platform hands to
/// anybody. This is an `https` URL on a **domain this project owns and
/// serves**, claimed by a certificate fingerprint Google checks: nothing
/// else can send it, and it means one thing.
///
/// Strict on every part, because a link is an input from outside: the scheme
/// must be `https`, the host must be exactly the service's own (no
/// subdomain, no lookalike), the path must be the link page's, and `s` must
/// be there and non-empty. Anything else is not a pairing link and is
/// dropped — the caller treats null as "some other link", never as an error.
String? drivePairingSessionOfLink(
  String link, {
  String origin = XtremioDrivePairingService.defaultOrigin,
}) {
  final url = Uri.tryParse(link);
  final home = Uri.tryParse(origin);
  if (url == null || home == null) return null;
  if (url.scheme != 'https' || url.host != home.host) return null;
  // `cleanUrls` on the hosting side serves the page at both spellings, and a
  // QR read by a camera can arrive as either.
  if (url.path != '/link' && url.path != '/link.html') return null;
  final session = url.queryParameters['s'];
  if (session == null || session.isEmpty) return null;
  return session;
}

/// One file as the pairing service names it: what the viewer picked, before
/// this device has written anything down about it.
///
/// A record and not a class, so that [DriveAccount.linkFiles] can name the
/// same shape structurally and the account need not depend on the pairing
/// service's types. It is three strings out of somebody else's JSON; the
/// row this device keeps is [LinkedDriveFile], which is stamped from the
/// account's own clock and is a class for that reason.
///
/// * `fileId` -- Drive's own id, the only field that has to be right, since
///   it is what a byte range is asked for.
/// * `name` -- what the file is called in their Drive, for the list they
///   are shown.
/// * `mimeType` -- what Drive says it is (`video/x-matroska`). Empty when
///   the Picker sent none, which is no worse than a wrong one.
typedef DrivePairingFile = ({String fileId, String name, String mimeType});

/// One file out of a `ready` body, or null when it is not one this build can
/// use.
///
/// A row with no id is nothing -- the id is what a request is made against
/// -- and is dropped rather than failing the whole answer: one unreadable
/// row out of twelve should not lose the eleven, and the session is deleted
/// either way. Everything else has an answer for being missing, the same
/// answers [LinkedDriveFile.fromJson] gives.
DrivePairingFile? _pairedFile(Object? json) {
  if (json is! Map) return null;
  final fileId = json['fileId'];
  if (fileId is! String || fileId.trim().isEmpty) return null;
  final name = json['name'];
  final mimeType = json['mimeType'];
  return (
    fileId: fileId.trim(),
    name: name is String ? name : '',
    mimeType: mimeType is String ? mimeType : '',
  );
}

/// A session the service has opened: what to draw, and what to poll.
@immutable
final class DrivePairingSession {
  const DrivePairingSession({
    required this.sessionId,
    required this.link,
    required this.expiresAt,
  });

  /// The session's own id, which is what [DrivePairingService.collect] is
  /// called with. Not drawn: it is a UUID, and a UUID is not something a
  /// viewer reads off a television or types into a phone.
  final String sessionId;

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
    final link = json['link'];
    final expiresAt = json['expiresAt'];
    if (id is! String || id.trim().isEmpty) return null;
    if (link is! String || link.trim().isEmpty) return null;
    final until = expiresAt is String ? DateTime.tryParse(expiresAt) : null;
    if (until == null) return null;
    return DrivePairingSession(
      sessionId: id.trim(),
      link: link.trim(),
      expiresAt: until.toUtc(),
    );
  }

  /// Nothing about the session at all. The id is the whole of what a pairing
  /// is collected with -- anybody holding it can make the one read that
  /// hands over the credential -- so it is not written into a line either,
  /// and there is nothing else here worth naming.
  @override
  String toString() => 'DrivePairingSession()';
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
    required this.files,
  });

  /// The long-lived grant. **Never logged, never drawn, never put in a
  /// URL**: it does not expire on its own and it reaches every file the
  /// account has picked through this OAuth client. It goes from here into
  /// [DriveAccount.linkFiles] and nowhere else.
  final String refreshToken;

  /// Every file the viewer picked in the one Picker, in the order the Picker
  /// handed them over, and **never empty** -- a `ready` session with no
  /// readable file on it is [DrivePairingGone] instead, because there is
  /// nothing to link and nothing left to poll for.
  ///
  /// One is still the common case and is not a special one: a service that
  /// only ever named a single file answers as a list of one (see
  /// [XtremioDrivePairingService._readAnswer]).
  final List<DrivePairingFile> files;

  /// The files and never the token; see the library comment.
  @override
  String toString() =>
      'DrivePairingCollected(${files.map((file) => file.fileId).join(', ')})';
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

/// Which shape of device asked for a pairing. The only thing about the app
/// the service is told, and the only thing the pick page words itself
/// differently for.
///
/// **Three, not two.** A phone and a desktop are the same at the start --
/// both opened the browser themselves, on the screen the viewer is already
/// looking at -- and differ only at the end. `stremio://` is registered on
/// the phone, so the page can put the viewer back in front of the app; on a
/// desktop that registration is installed by hand or not at all
/// (`docs/DEEP_LINKS.md`), so a browser sent to the scheme would show an
/// error page where a confirmation should be, and the page has to say the
/// pairing is done and leave the window to be closed instead. A [television]
/// is the third: its viewer is looking at the other screen already and is
/// sent nowhere at all.
///
/// While this was one boolean -- did the session want a hand-back -- the
/// page had no way to tell the two shapes that do not want one apart, and
/// told a desktop its files were on the way to a television it has not got.
enum DrivePairingShape {
  television('tv'),
  phone('phone'),
  desktop('desktop');

  const DrivePairingShape(this.wire);

  /// What `POST /session` is sent, and what the service stores against the
  /// session for the pick page to read back.
  final String wire;

  /// Whether the pick page ends by sending this browser to
  /// [drivePairingHandBackLink]. The phone alone, and see the note above for
  /// why the desktop is not included.
  bool get handsBack => this == DrivePairingShape.phone;
}

/// The television's side of the pairing service. An interface because the
/// screen that drives it is walked by a widget test with a remote, and a
/// test must not reach the network.
abstract interface class DrivePairingService {
  /// Asks for a session: `POST /session`.
  ///
  /// [shape] tells the service which kind of device asked, and is the only
  /// thing the shapes differ by on the wire -- it decides how the pick page
  /// words its confirmation, and whether that page ends by sending the
  /// browser to [drivePairingHandBackLink]. See [DrivePairingShape] and
  /// `DrivePairingScreen`.
  Future<DrivePairingOpening> open({required DrivePairingShape shape});

  /// Asks what has happened to [sessionId]: `GET /session/{id}`.
  ///
  /// **Deletes the session** when it answers [DrivePairingCollected]. Call
  /// it once per session at a time and never again after that answer.
  Future<DrivePairingAnswer> collect(String sessionId);

  /// Hands a **native** pick to a waiting session: `POST /session/{id}/android`.
  ///
  /// The phone's half of the App Link flow, and the one call the browser
  /// never makes. A browser signs in and picks in two steps, so the service
  /// learns them separately; a phone doing both natively has them in the
  /// same instant, so this carries both and takes the session from waiting
  /// to ready in one go.
  ///
  /// [serverAuthCode] is a **credential** and belongs in no log line and on
  /// no screen. It is a one-time code issued for the *web* client, because
  /// that is the client the television's token belongs to: a `drive.file`
  /// grant is recorded against a user and a client, so a pick recorded
  /// against this app's Android client would grant the television nothing.
  ///
  /// Only ids are sent. The service reads the names itself with the
  /// credential it just minted, because a name is drawn on a television and
  /// matched against a catalogue, and is not a thing a client should be able
  /// to invent about somebody else's Drive.
  Future<DrivePairingHandover> handOverNativePick({
    required String sessionId,
    required String serverAuthCode,
    required List<String> fileIds,
  });
}

/// What became of a [DrivePairingService.handOverNativePick].
enum DrivePairingHandover {
  /// The session has it, and the television will collect it on its next poll.
  taken,

  /// The session is not there, or is no longer waiting for this — a code
  /// that timed out, or one already used. A fresh QR is the way on.
  gone,

  /// Google refused the code, or the grant it minted could not read the
  /// files that were picked. The second is the interesting one and the
  /// service says which, but to a viewer both mean "that did not work".
  refused,

  /// Nothing was reached. Worth retrying; nothing has been spent.
  unreachable,
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
  Future<DrivePairingOpening> open({required DrivePairingShape shape}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final answer = await _send(
        client,
        'POST',
        Uri.parse('$origin/session'),
        body: {'shape': shape.wire},
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
  @override
  Future<DrivePairingHandover> handOverNativePick({
    required String sessionId,
    required String serverAuthCode,
    required List<String> fileIds,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final answer = await _send(
        client,
        'POST',
        Uri.parse('$origin/session/$sessionId/android'),
        body: {'serverAuthCode': serverAuthCode, 'fileIds': fileIds},
      ).timeout(timeout);
      final status = answer.statusCode;
      await answer.drain<void>();
      return switch (status) {
        HttpStatus.ok => DrivePairingHandover.taken,
        // Not there, not waiting any more, or its ten minutes are up: all
        // three mean this session cannot be given anything, and all three
        // are answered by a fresh code rather than by trying again.
        HttpStatus.notFound ||
        HttpStatus.conflict ||
        HttpStatus.gone => DrivePairingHandover.gone,
        // `502` is Google refusing the code or the grant not reaching the
        // files; `400` is this app sending something malformed, which is a
        // bug rather than a retry.
        HttpStatus.badGateway ||
        HttpStatus.badRequest => DrivePairingHandover.refused,
        _ => DrivePairingHandover.unreachable,
      };
    } on Object {
      return DrivePairingHandover.unreachable;
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
  ///
  /// **Two spellings of the files, and `files` wins.** A `ready` body names
  /// them as a list, and names the first of them again as `file` for a build
  /// that knows nothing of lists. This build reads the list when there is
  /// one and falls back to the single `file` when there is not, which is
  /// what a service from before several could be picked answers with -- and
  /// that is the whole of what an older service needs, since one file is a
  /// list of one and nothing here treats it as a special case.
  static DrivePairingAnswer _readAnswer(Map<String, dynamic>? json) {
    final status = json?['status'];
    if (status == 'pending') return const DrivePairingWaiting(signedIn: false);
    if (status == 'signed-in') {
      return const DrivePairingWaiting(signedIn: true);
    }
    if (status != 'ready') return const DrivePairingUnreachable();
    final token = json?['refreshToken'];
    if (token is! String || token.isEmpty) {
      // A `ready` with no grant on it is the one shape nothing can be
      // rescued from: the session is deleted either way, so there is
      // nothing left to poll for.
      return const DrivePairingGone();
    }
    final listed = json?['files'];
    final files = <DrivePairingFile>[
      if (listed is List)
        for (final one in listed) ?_pairedFile(one)
      else
        ?_pairedFile(json?['file']),
    ];
    // And a `ready` naming nothing this build can read is the same dead end
    // as one with no grant: the session is gone, so there is nothing to ask
    // again about.
    if (files.isEmpty) return const DrivePairingGone();
    return DrivePairingCollected(refreshToken: token, files: files);
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
    Uri url, {
    Map<String, Object?>? body,
  }) async {
    final request = await client.openUrl(method, url);
    // Nothing here follows a redirect: both routes answer JSON directly,
    // and the one redirect the service issues is the phone's.
    request.followRedirects = false;
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
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
