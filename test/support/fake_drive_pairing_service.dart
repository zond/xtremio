import 'dart:async';

import 'package:xtremio/core/core.dart';

/// The moment every pairing test is pinned to, so a session's window is a
/// number a test can reason about rather than whatever the machine's clock
/// says while the suite runs.
final DateTime pairingNow = DateTime.utc(2026, 9, 25, 20);

/// Not a token. A marker a test can search a widget tree, the log ring and
/// a copied diagnostics report for -- it is not a credential and it is not
/// the shape of one, and a real refresh token must never be written into a
/// fixture, a test or a comment (`AGENTS.md`, "Never log auth material").
const String fakeRefreshToken = 'fake-refresh-token-for-tests-only';

/// A [DrivePairingService] a test drives by hand.
///
/// Two queues and a count. [openings] is what `POST /session` answers, one
/// per call, falling back to [session] once it runs dry; [answers] is what
/// `GET /session/{id}` answers, one per call, with the *last* one repeating
/// forever so a test can say "waiting, waiting, then the pairing" without
/// counting how many polls the screen will make. [collects] is every
/// session id that was asked about, in order, which is how a test tells
/// "the polling stopped" from "the screen merely stopped drawing".
///
/// Nothing here reaches a network, and nothing here is a real credential:
/// what a collected pairing carries is [fakeRefreshToken].
class FakeDrivePairingService implements DrivePairingService {
  FakeDrivePairingService({
    DrivePairingSession? session,
    List<DrivePairingOpening>? openings,
    List<DrivePairingAnswer>? answers,
  }) : session = session ?? fakeSession(),
       openings = [...?openings],
       answers = [...?answers];

  /// The session handed out when [openings] has nothing to say.
  final DrivePairingSession session;

  final List<DrivePairingOpening> openings;
  final List<DrivePairingAnswer> answers;

  /// Every `POST /session`, counted.
  int opens = 0;

  /// Every `GET /session/{id}`, by the id it was made with.
  final List<String> collects = [];

  /// While this is set, the next [collect] hangs on it instead of
  /// answering: what a test needs to leave a poll in flight while the
  /// screen goes away.
  Completer<DrivePairingAnswer>? hold;

  @override
  Future<DrivePairingOpening> open() async {
    opens++;
    if (openings.isEmpty) return DrivePairingOpened(session);
    return openings.removeAt(0);
  }

  @override
  Future<DrivePairingAnswer> collect(String sessionId) async {
    collects.add(sessionId);
    final holding = hold;
    if (holding != null) {
      hold = null;
      return holding.future;
    }
    if (answers.isEmpty) return const DrivePairingWaiting(signedIn: false);
    return answers.length == 1 ? answers.first : answers.removeAt(0);
  }
}

/// A session as the service describes one, ten minutes from [pairingNow].
DrivePairingSession fakeSession({
  String id = 'session-1',
  String code = 'K7M2QX',
  Duration lasts = const Duration(minutes: 10),
}) => DrivePairingSession(
  sessionId: id,
  code: code,
  link: 'https://xtremio-drive.web.app/link?s=$id',
  expiresAt: pairingNow.add(lasts),
);

/// A pairing as the service hands one over.
DrivePairingCollected fakeCollected({
  String name = 'Arrival (2016) 2160p.mkv',
  String fileId = 'drive-file-1',
  String mimeType = 'video/x-matroska',
}) => DrivePairingCollected(
  refreshToken: fakeRefreshToken,
  fileId: fileId,
  name: name,
  mimeType: mimeType,
);
