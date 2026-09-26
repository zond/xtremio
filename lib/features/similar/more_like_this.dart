/// The whole of "More like this" behind the row: ask, guard, remember.
///
/// A row on a title asks this one question -- *what is like this?* -- and
/// everything that can go wrong with the answer is answered here with an
/// empty list. A server that is busy or unreachable, a title it does not
/// know, a catalogue that did not answer: all of them are a title with no
/// row under it, which is the same thing a film nothing resembles looks
/// like. **Nothing in this file throws.**
///
/// The order is deliberate and it is the whole design:
///
/// 1. **What was answered before, if anything was.** The first answer is
///    the answer, for the life of the install (`SimilarMemory`) -- the
///    same model asked twice agrees with itself about half the time, and a
///    row that reshuffles on every visit is one nobody can point at. Only
///    an answer to the question this build knows counts as one
///    (`similarQuestionVersion`); an older one is asked again.
/// 2. **The server, once per title per install.** It asks the model once
///    per title for everybody and keeps that answer, so this is the second
///    of two caches and usually a read. Only `movie` and `series` are
///    asked about -- the server takes nothing else, and a type it would
///    refuse is not worth a request to be told so.
/// 3. **The guard**, which is not optional and is documented where it
///    lives (`similar_resolver.dart`).
///
/// There is no way past any of it. A viewer who dislikes a row has no
/// "ask again": the server's answer is everybody's, and a re-ask anybody
/// could send would re-bill a title without end and replace the answer
/// for every other install.
///
/// What the row itself does with the result -- how many it shows, what a
/// reason looks like on a television -- is not here. This hands back
/// catalogue items and the model's sentence about each.
library;

import '../../core/core.dart';
import 'similar_resolver.dart';
import 'similar_titles.dart';
import 'xtremio_similar_titles.dart';

final class MoreLikeThis {
  MoreLikeThis({
    required this.prefs,
    SimilarTitlesProvider? provider,
    this.search = cinemetaSearch,
  }) : provider = provider ?? XtremioSimilarTitles();

  /// Where the remembered answers live.
  final AppPrefs prefs;

  /// Where a title nobody on this device has asked about is asked. A test
  /// hands one that answers without a network; nothing else does.
  final SimilarTitlesProvider provider;

  /// How a suggestion is checked against a catalogue -- injected for the
  /// same reason and in the same shape as `PlaybackScope.archiveSniff`.
  final CatalogueSearch search;

  /// What has already been resolved this run, by `type/id`.
  ///
  /// The suggestions are remembered across restarts and the *resolution*
  /// is not: it is a handful of searches against whatever the catalogues
  /// hold today, and a poster that changed is a poster that should change.
  /// Within one run, though, going back to a title should not ask again.
  final Map<String, List<SimilarTitle>> _resolved = {};

  /// The types the server answers for: Stremio's own `movie` and `series`.
  static const Set<String> _askable = {'movie', 'series'};

  /// Titles like the item [id] of [type] on screen.
  ///
  /// Empty is an ordinary answer, and every failure is one. A [type] other
  /// than `movie` or `series` is empty without asking anybody, and nothing
  /// is remembered about it.
  Future<List<SimilarTitle>> forItem({
    required String type,
    required String id,
  }) async {
    if (!_askable.contains(type)) return const [];
    final key = '$type/$id';
    if (_resolved[key] case final already?) return already;
    final suggestions = await _suggestionsFor(type: type, id: id);
    final resolved = await resolveSuggestions(
      suggestions,
      subjectId: id,
      search: search,
    );
    return _resolved[key] = resolved;
  }

  /// What the model said about this title: off the preferences file when
  /// this device has asked before, off the server when it has not, and an
  /// empty list when the ask failed.
  Future<List<SuggestedTitle>> _suggestionsFor({
    required String type,
    required String id,
  }) async {
    final remembered = prefs.similarSuggestions.forItem(type: type, id: id);
    if (remembered != null) return remembered;
    final List<SuggestedTitle> answered;
    try {
      answered = await provider.suggest(type: type, id: id);
    } on SimilarTitlesFailure catch (failure) {
      // Which failure it was, so that a row that never appears has an
      // explanation a week later.
      DiagnosticsLog.info(
        'similar',
        'no suggestions for $type $id: '
            '${failure.trouble.describe}${failure.detail == null ? '' : ' (${failure.detail})'}',
      );
      return const [];
    } on Object catch (error) {
      // A provider that threw something else is still just a row that
      // does not appear.
      DiagnosticsLog.info(
        'similar',
        'no suggestions for $type $id: ${error.runtimeType}',
      );
      return const [];
    }
    // Written down even when it is empty: an answer with nothing in it is
    // an answer, and the server would only say it again.
    await prefs.setSimilarSuggestions(
      prefs.similarSuggestions.remembering(
        type: type,
        id: id,
        suggestions: answered,
      ),
    );
    return answered;
  }
}
