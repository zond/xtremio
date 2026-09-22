/// The whole of "More like this" behind the row: ask, guard, remember.
///
/// A row on a title asks this one question -- *what is like this?* -- and
/// everything that can go wrong with the answer is answered here with an
/// empty list. No key configured, a model that is gone, a provider that
/// took too long, a catalogue that did not answer: all of them are a title
/// with no row under it, which is the same thing a film nothing resembles
/// looks like. **Nothing in this file throws.**
///
/// The order is deliberate and it is the whole design:
///
/// 1. **What was answered before, if anything was.** The first answer is
///    the answer, for the life of the install (`SimilarMemory`) -- the
///    same model asked twice agrees with itself about half the time, and a
///    row that reshuffles on every visit is one nobody can point at. Only
///    an answer to the question this build asks counts as one
///    (`similarQuestionVersion`); an older one is asked again.
/// 2. **The model, only with a key and only once per title.** With no key
///    configured nothing is asked of any provider at all -- not a probe,
///    not a default key, nothing: there is no key in this repository and
///    there is not going to be one.
/// 3. **The guard**, which is not optional and is documented where it
///    lives (`similar_resolver.dart`).
///
/// And one way past all of it: `afresh`, which is the viewer saying the
/// row is wrong. It steps over both caches and writes the new answer over
/// the old one -- but only when there is a new answer to write, because
/// every failure here is an empty list and a row the viewer was looking at
/// is not a thing a failure may take away. See [MoreLikeThis.forItem].
///
/// What the row itself does with the result -- how many it shows, what a
/// reason looks like on a television -- is not here. This hands back
/// catalogue items and the model's sentence about each.
library;

import '../../core/core.dart';
import 'gemini_similar_titles.dart';
import 'similar_resolver.dart';
import 'similar_titles.dart';

/// How a provider is built once the key and the model are known.
///
/// A factory rather than a provider, because both of its arguments are
/// *preferences*: the viewer can paste a new key or name another model
/// between one title and the next, and a provider built at start-up would
/// be holding the old ones.
typedef SimilarProviderFactory = SimilarTitlesProvider Function({
  required String apiKey,
  required String model,
});

/// What the app uses: Google's API, the model named in preferences.
SimilarTitlesProvider _googleProvider({
  required String apiKey,
  required String model,
}) => GeminiSimilarTitles(apiKey: apiKey, model: model);

final class MoreLikeThis {
  MoreLikeThis({
    required this.prefs,
    this.providerFor = _googleProvider,
    this.search = cinemetaSearch,
  });

  /// Where the key, the model and the remembered answers live.
  final AppPrefs prefs;

  /// How the provider is built, once there is a key to build it with. A
  /// test hands one that answers without a network; nothing else does.
  final SimilarProviderFactory providerFor;

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

  /// Titles like [name] ([year]), the item [id] of [type] on screen.
  ///
  /// Empty is an ordinary answer, and every failure is one.
  ///
  /// [afresh] is the viewer having pressed "ask again": the model is asked
  /// about this title whatever is written down about it, and the answer
  /// replaces what was. Two things about it are the whole of the feature:
  ///
  ///  * **Both caches are stepped over**, and they are two -- the answer
  ///    remembered under this title and the resolution of it this run. A
  ///    remembered *empty* answer is a value here and normally stops the
  ///    asking, which makes it exactly the row somebody presses this for.
  ///  * **The row is replaced only when something came back to replace it
  ///    with.** Everything that can go wrong is an empty list by design
  ///    (see the top of this file), so a provider that is gone and a model
  ///    with nothing to say arrive looking the same -- and neither is
  ///    grounds for blanking a row that was fine, which is the one thing
  ///    the press must not cost. An empty re-ask therefore writes nothing
  ///    and caches nothing: what was remembered stands, and the next press
  ///    asks again.
  Future<List<SimilarTitle>> forItem({
    required String type,
    required String id,
    required String name,
    int? year,
    bool afresh = false,
  }) async {
    final key = '$type/$id';
    if (!afresh) {
      if (_resolved[key] case final already?) return already;
    }
    final suggestions = await _suggestionsFor(
      type: type,
      id: id,
      name: name,
      year: year,
      afresh: afresh,
    );
    final resolved = await resolveSuggestions(
      suggestions,
      subjectId: id,
      search: search,
    );
    if (afresh) {
      // The guard can empty a model's answer on its own -- ten invented
      // titles resolve to nothing -- so the test is on what would reach
      // the screen and not on what the model said. That keeps the row, the
      // per-run resolution and the preferences file saying one thing.
      if (resolved.isEmpty) return const [];
      await _remember(type: type, id: id, suggestions: suggestions);
    }
    return _resolved[key] = resolved;
  }

  /// What the model said about this title: off the preferences file when
  /// it has been asked before, off the provider when it has not, and an
  /// empty list when there is no key or the ask failed.
  Future<List<SuggestedTitle>> _suggestionsFor({
    required String type,
    required String id,
    required String name,
    int? year,
    required bool afresh,
  }) async {
    if (!afresh) {
      final remembered = prefs.similarSuggestions.forItem(type: type, id: id);
      if (remembered != null) return remembered;
    }
    final apiKey = prefs.similarApiKey;
    // No key, no provider. Not "ask and fail" -- ask *nothing*.
    if (apiKey == null) return const [];
    final model = prefs.similarModel;
    final provider = providerFor(apiKey: apiKey, model: model);
    final List<SuggestedTitle> answered;
    try {
      answered = await provider.suggest(
        year == null ? name : '$name ($year)',
        // Stremio's own `movie`/`series`, which is what the screen has,
        // turned into the question's vocabulary. Anything else -- a type
        // this app does not put a details screen under -- is asked about
        // as a film, which is the question that was measured.
        about: SuggestedKind.parse(type) ?? SuggestedKind.film,
      );
    } on SimilarTitlesFailure catch (failure) {
      // Which failure it was, so that a fallback to another model -- or a
      // viewer being told to pick one -- has grounds a week later. The
      // model's name is in the line; the key never is.
      DiagnosticsLog.info(
        'similar',
        'no suggestions for $type $id from $model: '
            '${failure.trouble.describe}${failure.detail == null ? '' : ' (${failure.detail})'}',
      );
      return const [];
    } on Object catch (error) {
      // A provider that threw something else is still just a row that
      // does not appear.
      DiagnosticsLog.info(
        'similar',
        'no suggestions for $type $id from $model: ${error.runtimeType}',
      );
      return const [];
    }
    // Written down even when it is empty: an answer with nothing in it is
    // an answer, and asking again would cost a call to be told it twice.
    // A re-ask writes nothing here -- it writes after the guard has run,
    // and only if anything survived it ([forItem]).
    if (!afresh) await _remember(type: type, id: id, suggestions: answered);
    return answered;
  }

  /// [suggestions] written down under this title, stamped with the question
  /// that produced them and moved to the front of the recency order
  /// ([SimilarMemory.remembering]), replacing whatever was there.
  Future<void> _remember({
    required String type,
    required String id,
    required List<SuggestedTitle> suggestions,
  }) => prefs.setSimilarSuggestions(
    prefs.similarSuggestions.remembering(
      type: type,
      id: id,
      suggestions: suggestions,
    ),
  );
}
