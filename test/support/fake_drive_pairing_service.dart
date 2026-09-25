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

  /// What shape each `POST /session` said it was, in order: the one thing
  /// the service is told about the device that is pairing, and what the pick
  /// page words its confirmation from.
  final List<DrivePairingShape> shapes = [];

  /// Called on every collect, for a test that counts them without caring
  /// which id each one used.
  void Function()? onCollect;

  /// Every `GET /session/{id}`, by the id it was made with.
  final List<String> collects = [];

  /// While this is set, the next [collect] hangs on it instead of
  /// answering: what a test needs to leave a poll in flight while the
  /// screen goes away.
  Completer<DrivePairingAnswer>? hold;

  @override
  Future<DrivePairingOpening> open({required DrivePairingShape shape}) async {
    opens++;
    shapes.add(shape);
    if (openings.isEmpty) return DrivePairingOpened(session);
    return openings.removeAt(0);
  }

  /// Every native hand-over, by session and how many ids came with it.
  /// **Never the code**: a fake that recorded a credential would be the one
  /// place in the suite where one is kept, and a test that asserts on a code
  /// is a test that would have to hold one.
  final List<({String sessionId, int files})> handovers = [];

  /// What [handOverNativePick] answers, in order; the last stands.
  List<DrivePairingHandover> handoverAnswers = [DrivePairingHandover.taken];

  @override
  Future<DrivePairingHandover> handOverNativePick({
    required String sessionId,
    required String serverAuthCode,
    required List<String> fileIds,
  }) async {
    handovers.add((sessionId: sessionId, files: fileIds.length));
    return handoverAnswers.length > 1
        ? handoverAnswers.removeAt(0)
        : handoverAnswers.first;
  }

  @override
  Future<DrivePairingAnswer> collect(String sessionId) async {
    collects.add(sessionId);
    onCollect?.call();
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
  Duration lasts = const Duration(minutes: 10),
}) => DrivePairingSession(
  sessionId: id,
  link: 'https://xtremio-drive.web.app/link?s=$id',
  expiresAt: pairingNow.add(lasts),
);

/// A pairing as the service hands one over: one file, which is the common
/// case. [fakeCollectedFiles] is the same pairing with a season on it.
DrivePairingCollected fakeCollected({
  String name = 'Arrival (2016) 2160p.mkv',
  String fileId = 'drive-file-1',
  String mimeType = 'video/x-matroska',
}) => DrivePairingCollected(
  refreshToken: fakeRefreshToken,
  files: [(fileId: fileId, name: name, mimeType: mimeType)],
);

/// A pairing carrying several files, in the order the Picker handed them
/// over.
DrivePairingCollected fakeCollectedFiles([
  List<String> names = const [
    'Gilmore Girls S01E01.mkv',
    'Gilmore Girls S01E02.mkv',
    'Gilmore Girls S01E03.mkv',
  ],
]) => DrivePairingCollected(
  refreshToken: fakeRefreshToken,
  files: [
    for (var i = 0; i < names.length; i++)
      (
        fileId: 'drive-file-${i + 1}',
        name: names[i],
        mimeType: 'video/x-matroska',
      ),
  ],
);
