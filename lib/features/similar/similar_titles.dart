/// Where "More like this" suggestions come from, and what asking for them
/// can go wrong with.
///
/// The question is not asked here. It lives on the xtremio-drive server
/// (`xtremio-xervice/functions/similar.js`), which holds the one Gemini key
/// there is, asks the model once per title, and hands the same answer to
/// every install after that. What is measured about the model and the
/// wording lives in `tool/recommendations/`; none of it is this app's to
/// choose any more, which is the point -- a viewer used to need a key of
/// their own before the row appeared at all, and nobody but the owner had
/// one.
library;

import '../../core/core.dart';

/// How long one ask is allowed to take.
///
/// Twenty seconds, which is long for a request and deliberate: the first
/// device to open a title is the one that waits while the server asks the
/// model, and every device after it reads a stored answer in a fraction of
/// that. The row is late by design -- it appears under a Details screen
/// that is already usable -- so waiting costs the viewer nothing, and
/// abandoning early would only make the first ask of every title fail.
const Duration similarBudget = Duration(seconds: 20);

/// Where suggestions come from.
///
/// An interface with one implementation (`XtremioSimilarTitles`) so that a
/// test can answer without a network, and so the row does not know the
/// shape of any one server's request.
///
/// Nothing here promises the titles exist. That is [resolveSuggestions]'s
/// job, and it is not optional.
abstract interface class SimilarTitlesProvider {
  /// What is like the item [id] (a Cinemeta id, `tt0063350`) of [type]
  /// (`movie` or `series`) -- or a [SimilarTitlesFailure].
  ///
  /// Throws rather than answering empty, because the two mean different
  /// things to everything upstream: empty is a server that answered and had
  /// nothing to say, and a failure is one that could not be asked. An
  /// empty answer is cached; a failure is not.
  Future<List<SuggestedTitle>> suggest({
    required String type,
    required String id,
  });
}

/// The kinds of not-answering, told apart so a log line can say which.
///
/// The list is what the server can answer with (and what can happen before
/// it answers at all), not what the model behind it can: the server
/// classifies the model's own failures and reports them as one.
enum SimilarTrouble {
  /// 404: the server does not know the title -- Cinemeta had nothing under
  /// that id.
  unknownTitle('title unknown'),

  /// 503: another request for the same title is still waiting on the
  /// model. Fixes itself; the next opening of the title reads its answer.
  busy('server busy with this title'),

  /// Any other status that is not 200: the model or the catalogue failed
  /// behind the server (502), the server did (500), or it would not take
  /// the type or id (400 -- which the caller never sends, since it asks
  /// only about `movie` and `series`).
  unavailable('server could not answer'),

  /// The budget passed with no answer ([similarBudget]).
  tooSlow('no answer in time'),

  /// An answer arrived and was not the documented shape, or was not JSON.
  malformed('answer not understood'),

  /// No HTTP at all: no network, DNS, TLS, a host that is not there.
  unreachable('server unreachable');

  const SimilarTrouble(this.describe);

  /// A few words for the log. Never carries a URL.
  final String describe;
}

/// Why nothing was suggested. Carries [trouble] so that the caller can log
/// which of the failures it was without parsing a sentence.
final class SimilarTitlesFailure implements Exception {
  const SimilarTitlesFailure(this.trouble, [this.detail]);

  final SimilarTrouble trouble;

  /// What else is worth keeping -- a status code, an exception's type.
  /// **Never a body or a URL**, because this is written to the log.
  final String? detail;

  @override
  String toString() => detail == null
      ? 'SimilarTitlesFailure(${trouble.describe})'
      : 'SimilarTitlesFailure(${trouble.describe}: $detail)';
}
