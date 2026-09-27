/// [SimilarTitlesProvider] over the xtremio-xervice server's `/similar`.
///
/// One `GET {base}/similar/{type}/{id}`, answered with
/// `{"titles":[{"title","year","kind","why"}, …], "version": 1}`. The server
/// (`xtremio-xervice/functions/similar.js`) holds the Gemini key, builds the
/// question from the name and year Cinemeta has for the id, and keeps the
/// first answer for a title for everybody -- so nothing is sent from here
/// but a type and an id, and there is nothing secret in this file or in
/// the request.
///
/// Every failure comes back as a [SimilarTrouble] rather than an exception
/// to print, so a log read a week later can say *the server was busy with
/// that title* rather than *it did not work*.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/core.dart';
import 'similar_titles.dart';

/// Where the xtremio-xervice server lives: the Firebase Hosting site that
/// also serves Drive pairing, which rewrites `/similar/**` to the function.
const String xtremioDriveBase = XtremioDrivePairingService.defaultOrigin;

final class XtremioSimilarTitles implements SimilarTitlesProvider {
  XtremioSimilarTitles({Uri? base, this.budget = similarBudget})
    : base = base ?? Uri.parse(xtremioDriveBase);

  /// The server's origin. A parameter so a test answers it from the
  /// loopback and nothing in this file knows the difference.
  final Uri base;

  /// The whole ask. Past it the request is abandoned and the socket closed
  /// under it.
  final Duration budget;

  @override
  Future<List<SuggestedTitle>> suggest({
    required String type,
    required String id,
  }) async {
    final client = HttpClient()..connectionTimeout = budget;
    try {
      return await _ask(client, type, id).timeout(budget);
    } on TimeoutException {
      throw const SimilarTitlesFailure(SimilarTrouble.tooSlow);
    } on SimilarTitlesFailure {
      rethrow;
    } on Object catch (error) {
      // No HTTP at all: no network, no DNS, a TLS refusal. The type is
      // worth keeping and the message is not -- it can carry the URL.
      throw SimilarTitlesFailure(
        SimilarTrouble.unreachable,
        error.runtimeType.toString(),
      );
    } finally {
      // Force, because [budget] may have passed while a response was
      // still arriving: closing the client is what actually abandons it.
      client.close(force: true);
    }
  }

  Future<List<SuggestedTitle>> _ask(
    HttpClient client,
    String type,
    String id,
  ) async {
    // Segments rather than a formatted string, so an id is always one
    // escaped path segment whatever is in it.
    final url = base.replace(
      pathSegments: [
        ...base.pathSegments.where((segment) => segment.isNotEmpty),
        'similar',
        type,
        id,
      ],
    );
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw SimilarTitlesFailure(
        _troubleFor(response.statusCode),
        '${response.statusCode}',
      );
    }
    return _titlesIn(text);
  }

  /// What a status code means, in the words a log can be read back in --
  /// the statuses `similar.js` answers with.
  static SimilarTrouble _troubleFor(int status) => switch (status) {
    HttpStatus.notFound => SimilarTrouble.unknownTitle,
    HttpStatus.serviceUnavailable => SimilarTrouble.busy,
    _ => SimilarTrouble.unavailable,
  };

  /// The titles in a documented answer.
  ///
  /// Anything that is not that shape is [SimilarTrouble.malformed] rather
  /// than an empty answer: an answer that was not understood must not be
  /// cached as "this title is like nothing".
  static List<SuggestedTitle> _titlesIn(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const SimilarTitlesFailure(SimilarTrouble.malformed, 'not JSON');
    }
    final titles = decoded is Map ? decoded['titles'] : null;
    if (titles is! List) {
      throw const SimilarTitlesFailure(SimilarTrouble.malformed, 'titles');
    }
    // A row that cannot be read is one suggestion lost, not an answer
    // lost. The server passes a year or a kind it could not read on as
    // null; a null year is a row dropped here (a suggestion without a
    // year cannot be told from an unrelated film of the same name -- see
    // [SuggestedTitle.year]), and a null kind is a row resolved against
    // both catalogues.
    return [for (final title in titles) ?SuggestedTitle.fromJson(title)];
  }
}
