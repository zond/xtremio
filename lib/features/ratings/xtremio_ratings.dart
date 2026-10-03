/// A title's scores, asked of the xtremio-xervice server and remembered.
///
/// One `GET {base}/ratings/{type}/{id}`, answered with
/// `{"imdb": {"score", "votes"?} | null, "tmdb": …, "tomatoes": …,
/// "popcorn": …, "fetchedAt": …}`. The server
/// (`xtremio-xervice/functions/ratings.js`) holds the MDBList key and asks
/// MDBList once a week per title for everybody, so nothing is sent from
/// here but a type and an id.
///
/// **Scores never stand in the way of the page.** Every failure is the
/// scores that were already known, or none; nothing here throws to a
/// caller, and the details header draws whatever it has the moment it has
/// it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/core.dart';

/// Where the scores come from.
///
/// An interface with one implementation ([XtremioRatings]) so a test can
/// answer without a network.
abstract interface class RatingsProvider {
  /// The scores the server has for [id] (a Cinemeta `tt…` id) of [type]
  /// (`movie` or `series`), or a [RatingsFailure].
  Future<TitleRatings> ratings({required String type, required String id});
}

/// Why no scores came back. [detail] is a status code or an exception's
/// type -- **never a body or a URL**, because it is written to the log.
final class RatingsFailure implements Exception {
  const RatingsFailure(this.detail);

  final String detail;

  @override
  String toString() => 'RatingsFailure($detail)';
}

/// How long one ask may take. Short: the scores are a garnish on a screen
/// that is already usable, and the server answers from its store.
const Duration ratingsBudget = Duration(seconds: 10);

final class XtremioRatings implements RatingsProvider {
  XtremioRatings({Uri? base, this.budget = ratingsBudget})
    : base = base ?? Uri.parse(XtremioDrivePairingService.defaultOrigin);

  /// The server's origin. A parameter so a test answers it from the
  /// loopback.
  final Uri base;

  final Duration budget;

  @override
  Future<TitleRatings> ratings({
    required String type,
    required String id,
  }) async {
    final client = HttpClient()..connectionTimeout = budget;
    try {
      return await _ask(client, type, id).timeout(budget);
    } on TimeoutException {
      throw const RatingsFailure('no answer in time');
    } on RatingsFailure {
      rethrow;
    } on Object catch (error) {
      // The type is worth keeping and the message is not: it can carry
      // the URL.
      throw RatingsFailure(error.runtimeType.toString());
    } finally {
      client.close(force: true);
    }
  }

  Future<TitleRatings> _ask(HttpClient client, String type, String id) async {
    final url = base.replace(
      pathSegments: [
        ...base.pathSegments.where((segment) => segment.isNotEmpty),
        'ratings',
        type,
        id,
      ],
    );
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw RatingsFailure('${response.statusCode}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const RatingsFailure('not JSON');
    }
    if (decoded is! Map) throw const RatingsFailure('not an object');
    return TitleRatings.fromJson(decoded);
  }
}

/// The scores for a title: remembered on the device, asked of the server
/// when they are missing or a day old.
final class RatingsService {
  RatingsService({
    required this.prefs,
    RatingsProvider? provider,
    DateTime Function()? now,
  }) : provider = provider ?? XtremioRatings(),
       now = now ?? DateTime.now;

  /// Where remembered scores live ([AppPrefs.titleRatings]).
  final AppPrefs prefs;

  final RatingsProvider provider;

  /// The clock, a parameter so a test can age a remembered answer.
  final DateTime Function() now;

  /// What the server answers for: Stremio's `movie` and `series`, by an
  /// IMDb id. Anything else is not asked about -- the server would refuse
  /// it.
  static bool askable({required String type, required String id}) =>
      (type == 'movie' || type == 'series') && _imdbId.hasMatch(id);

  static final RegExp _imdbId = RegExp(r'^tt\d{1,12}$');

  /// What this device was told about the title, however old. Synchronous,
  /// so the header can draw it in its first frame.
  TitleRatings? remembered({required String type, required String id}) =>
      prefs.titleRatings.forItem(type: type, id: id)?.ratings;

  /// Newer scores than [remembered], or null when there is nothing newer:
  /// the remembered ones are under a day old, the title is not one the
  /// server answers for, the server failed, or it had no score at all.
  ///
  /// An answer with no scores is not written down, so a title MDBList had
  /// not heard of yet -- or a day the server could not ask it -- does not
  /// hide the scores for a day once there are some.
  Future<TitleRatings?> refreshed({
    required String type,
    required String id,
  }) async {
    if (!askable(type: type, id: id)) return null;
    final entry = prefs.titleRatings.forItem(type: type, id: id);
    if (entry != null && entry.isFreshAt(now())) return null;
    final TitleRatings answer;
    try {
      answer = await provider.ratings(type: type, id: id);
    } on RatingsFailure catch (failure) {
      DiagnosticsLog.info('ratings', 'no ratings for $type $id: $failure');
      return null;
    } on Object catch (error) {
      DiagnosticsLog.info(
        'ratings',
        'no ratings for $type $id: ${error.runtimeType}',
      );
      return null;
    }
    if (answer.isEmpty) return null;
    await prefs.setTitleRatings(
      prefs.titleRatings.remembering(
        type: type,
        id: id,
        ratings: answer,
        at: now(),
      ),
    );
    return answer;
  }
}
