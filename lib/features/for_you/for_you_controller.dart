/// The For you row's work: asking, ranking, resolving, and remembering the
/// answer.
///
/// The rules are in `for_you_rules.dart`. This is when they run and what they
/// are fed. It runs on the device, from the library the engine holds (all of
/// it, removed and temporary items too: `CoreField.libraryItems`), the faces,
/// and three questions asked over the network. Those are each source's "More
/// like this" answer, a watched series' episode list, and the catalogue search
/// that confirms a suggestion exists. Each goes through a [TaskLimiter] of
/// [ForYouController.concurrency], one for the server's answers and episode
/// lists and another for the searches, so a first run over a big library is a
/// trickle and not a burst.
///
/// **What is kept.** The ranked, resolved titles with their reasons, when they
/// were worked out, and a signature of the sources they came from (the `forYou`
/// preference). The row draws that at once on the next start. It is worked out
/// again when the signature changes (a title watched through or added, a face
/// given or taken), and otherwise at most once a day
/// ([ForYouController.refreshEvery]). A first run with nothing kept shows the
/// row as soon as the first answers are in and fills it as the rest arrive. A
/// later one swaps the whole row when it is done.
///
/// **A source that did not answer.** A failed ask is not an empty answer. The
/// run ranks what did answer, and its row replaces the viewer's only when it
/// is at least as long. It is kept as incomplete, and worked out again after
/// [ForYouController.retryAfter] instead of a day. A run where nothing
/// answered (offline) leaves the row as it is.
///
/// **What is not asked twice.** A source's suggestions go through
/// `MoreLikeThis` and its `similarSuggestions` memory, so a title already
/// opened on its details page costs nothing here. A show's episodes are kept
/// per show (`ShowEpisodesMemory`). A catalogue search is kept for the life of
/// the controller.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';

import '../../core/core.dart';
import '../similar/more_like_this.dart';
import '../similar/similar_resolver.dart';
import 'for_you_rules.dart';
import 'show_episodes.dart';

/// How a source's suggestions are asked for: `MoreLikeThis.suggestionsFor`.
/// Null when the ask failed, which is not an answer with nothing in it.
typedef SuggestionsAsk = Future<List<SuggestedTitle>?> Function({
  required String type,
  required String id,
});

/// The three questions the row asks, together, so a test answers them all.
final class ForYouAsk {
  const ForYouAsk({
    required this.suggest,
    required this.search,
    required this.episodes,
  });

  /// The real ones: the server's "More like this" through the device's
  /// memory of it, and Cinemeta.
  factory ForYouAsk.live(AppPrefs prefs) => ForYouAsk(
    suggest: MoreLikeThis(prefs: prefs).suggestionsFor,
    search: cinemetaSearch,
    episodes: cinemetaEpisodes,
  );

  final SuggestionsAsk suggest;
  final CatalogueSearch search;
  final EpisodesFetch episodes;
}

/// Supplies how the row asks, for Discover. Without one, the real questions are
/// asked.
class ForYouScope extends InheritedWidget {
  const ForYouScope({super.key, required this.askFor, required super.child});

  final ForYouAsk Function(AppPrefs prefs) askFor;

  static ForYouAsk Function(AppPrefs prefs) of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ForYouScope>()?.askFor ??
      ForYouAsk.live;

  @override
  bool updateShouldNotify(ForYouScope oldWidget) => askFor != oldWidget.askFor;
}

/// At most [max] of the tasks handed to [run] at once; the rest wait their
/// turn, first come first served.
final class TaskLimiter {
  TaskLimiter(this.max);

  final int max;
  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue();

  /// How many are running now.
  int get running => _running;

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= max) {
      final turn = Completer<void>();
      _waiting.add(turn);
      // The slot is handed over by the task that frees it ([_release]), so
      // nothing that arrives meanwhile can take it first.
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await task();
    } finally {
      _release();
    }
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _running--;
    }
  }
}

/// What the row shows, and the work behind it. Told the library and the
/// Continue watching row by [update]; reads the faces off [prefs].
class ForYouController extends ChangeNotifier {
  ForYouController({
    required this.prefs,
    required this.ask,
    this.now = DateTime.now,
  }) : _limiter = TaskLimiter(concurrency),
       _searches = TaskLimiter(concurrency);

  final AppPrefs prefs;
  final ForYouAsk ask;
  final DateTime Function() now;

  /// The shape of what is kept, part of its signature: a row kept by a
  /// build that stored less about its sources (before each line of the
  /// long-press sheet opened its title) is worked out again once.
  static const String keptShape = 'v2';

  /// The most questions out at once.
  static const int concurrency = 4;

  /// The most titles the row holds: a catalog row's.
  static const int maxTitles = 30;

  /// How many sources are asked about, the latest first. Ten suggestions
  /// each is already more candidates than the row can hold, and it keeps a
  /// run inside the `similarSuggestions` memory's 128 answers, leaving
  /// room for the details pages' own.
  static const int maxSources = 96;

  /// How old the kept answer may be before it is worked out again with
  /// nothing having changed.
  static const Duration refreshEvery = Duration(days: 1);

  /// How old a kept answer may be before it is worked out again when a
  /// source did not answer. The answers that came in are in the
  /// `similarSuggestions` memory by then, so only the failed sources reach
  /// the server again.
  static const Duration retryAfter = Duration(minutes: 10);

  /// The server's answers and the episode lists.
  final TaskLimiter _limiter;

  /// The catalogue searches, apart: a pass confirms the first answers
  /// while the rest are still queued behind [_limiter], which is what puts
  /// the row up before the last answer is in.
  final TaskLimiter _searches;

  List<LibraryItemView> _library = const [];
  Set<String> _continueWatching = const {};
  bool _told = false;

  /// What was worked out last, before today's exclusions.
  List<ForYouTitle> _worked = const [];

  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;

  final Map<String, Future<MetaItemPreview?>> _resolved = {};

  /// The row's titles: what was worked out, less anything the library,
  /// Continue watching or the faces have ruled out since.
  List<ForYouTitle> get titles {
    final out = _excluded();
    return [
      for (final title in _worked)
        if (!out.contains(title.item.id)) title,
    ];
  }

  /// Titles taken off the row by hand before the library says so: marked
  /// watched, which the library shows a moment later.
  final Set<String> _hidden = {};

  /// Takes [id] off the row now. The library or the faces say so for good once
  /// they have caught up.
  void hide(String id) {
    if (_hidden.add(id)) notifyListeners();
  }

  /// The ids no title of the row may be: in the library in any sense, on
  /// Continue watching, disliked, or dismissed.
  Set<String> _excluded() => {
    ..._hidden,
    for (final item in _library) item.id,
    ..._continueWatching,
    ...prefs.faces.idsWith(Face.dislike),
    ...prefs.faces.idsWith(Face.dismissed),
  };

  /// The engine's whole library and the ids on Continue watching, as they
  /// are now. Works the row out again when that changes what it would be.
  void update({
    required List<LibraryItemView> library,
    required Set<String> continueWatching,
  }) {
    _library = library;
    _continueWatching = continueWatching;
    if (!_told) {
      _told = true;
      _worked = _kept()?.titles ?? const [];
    }
    notifyListeners();
    _kick();
  }

  /// The faces changed: they rule titles out at once, and may change the
  /// sources too.
  void facesChanged() {
    if (!_told) return;
    notifyListeners();
    _kick();
  }

  void _kick() {
    if (_disposed) return;
    if (_running != null) {
      _again = true;
      return;
    }
    _running = _run().whenComplete(() {
      _running = null;
      if (_again) {
        _again = false;
        _kick();
      }
    });
  }

  /// The run in flight, for a test that waits for one to finish.
  @visibleForTesting
  Future<void> get settled async {
    while (_running != null) {
      await _running;
    }
  }

  ({DateTime at, String signature, List<ForYouTitle> titles, bool incomplete})?
  _kept() {
    final json = prefs.forYou;
    final at = json?['computedAt'];
    final signature = json?['signature'];
    final titles = json?['titles'];
    if (at is! int || signature is! String || titles is! List) return null;
    return (
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      signature: signature,
      titles: [for (final title in titles) ?ForYouTitle.fromJson(title)],
      incomplete: json?['incomplete'] == true,
    );
  }

  Future<void> _run() async {
    final library = _library;
    await _learnEpisodes(library);
    if (_disposed) return;
    final memory = prefs.showEpisodes;
    final all = forYouSources(
      library,
      prefs.faces,
      watchedThrough: (series) {
        final episodes = memory.of(series.id);
        return episodes != null && libraryItemWatchedThrough(series, episodes);
      },
    );
    final latest = ([
      ...all,
    ]..sort((a, b) => b.recency.compareTo(a.recency))).take(maxSources).toSet();
    final sources = [
      for (final source in all)
        if (latest.contains(source)) source,
    ];
    final signature = [
      keptShape,
      for (final s in sources) s.signature,
    ].join(',');
    final kept = _kept();
    if (kept != null &&
        kept.signature == signature &&
        now().toUtc().difference(kept.at) <
            (kept.incomplete ? retryAfter : refreshEvery)) {
      if (!identical(_worked, kept.titles) && _worked.isEmpty) {
        _worked = kept.titles;
        notifyListeners();
      }
      return;
    }
    if (sources.isEmpty) {
      _publish(const []);
      await _keep(signature, const []);
      return;
    }
    // Filled as it goes only when there is nothing to show meanwhile: a
    // row the viewer already has is swapped once, at the end.
    final had = _worked;
    final progressive = had.isEmpty;
    final answers = <String, List<SuggestedTitle>>{};
    var failed = 0;
    Future<void> passes = Future.value();
    var queued = false;
    void schedulePass() {
      if (queued) return;
      queued = true;
      passes = passes.then((_) async {
        queued = false;
        final titles = await _pass(sources, answers);
        if (!_disposed && progressive) _publish(titles);
      });
    }

    await Future.wait([
      for (final source in sources)
        _limiter.run(() => _suggestionsOf(source)).then((answer) {
          if (answer == null) {
            failed++;
            return;
          }
          answers[source.id] = answer;
          if (progressive) schedulePass();
        }),
    ]);
    await passes;
    if (_disposed) return;
    final titles = await _pass(sources, answers);
    if (_disposed) return;
    // A run with a failed source is short by that source's titles. It
    // replaces the viewer's row only when it is at least as long. A run
    // where nothing answered (offline) thus leaves the row as it is.
    final shown = failed > 0 && titles.length < had.length ? had : titles;
    _publish(shown);
    await _keep(signature, shown, incomplete: failed > 0);
  }

  /// [source]'s suggestions, or null when the ask failed.
  Future<List<SuggestedTitle>?> _suggestionsOf(ForYouSource source) async {
    try {
      return await ask.suggest(type: source.type, id: source.id);
    } on Object {
      return null;
    }
  }

  /// Fetches the episode list of every series that might be watched
  /// through and has none kept yet, the latest watched first, and keeps
  /// them in one write.
  Future<void> _learnEpisodes(List<LibraryItemView> library) async {
    final memory = prefs.showEpisodes;
    final dislikes = prefs.faces.idsWith(Face.dislike);
    final wanted =
        [
          for (final item in library)
            if (item.type == 'series' &&
                (item.watchedField ?? '').isNotEmpty &&
                !dislikes.contains(item.id) &&
                memory.of(item.id) == null)
              item,
        ]..sort(
          (a, b) => (b.lastWatched ?? DateTime(0)).compareTo(
            a.lastWatched ?? DateTime(0),
          ),
        );
    if (wanted.isEmpty) return;
    final learned = <String, List<ShowEpisode>>{};
    await Future.wait([
      for (final item in wanted.take(maxSources))
        _limiter.run(() async {
          try {
            final episodes = await ask.episodes(item.id);
            if (episodes != null && episodes.isNotEmpty) {
              learned[item.id] = episodes;
            }
          } on Object {
            // A show nobody could list is one not counted this run.
          }
        }),
    ]);
    if (learned.isEmpty || _disposed) return;
    var next = prefs.showEpisodes;
    for (final MapEntry(:key, :value) in learned.entries) {
      next = next.remembering(key, value);
    }
    await prefs.setShowEpisodes(next);
  }

  /// The row from the answers in so far: ranked, confirmed against the
  /// catalogue a few at a time in rank order, and cut at [maxTitles].
  Future<List<ForYouTitle>> _pass(
    List<ForYouSource> sources,
    Map<String, List<SuggestedTitle>> answers,
  ) async {
    final ranked = rankForYou(sources, answers);
    final out = _excluded()..addAll(sources.map((s) => s.id));
    final titles = <ForYouTitle>[];
    final seen = <String>{};
    const window = 8;
    for (var at = 0; at < ranked.length && titles.length < maxTitles;) {
      final batch = ranked.skip(at).take(window).toList();
      at += batch.length;
      final items = await Future.wait(batch.map(_resolve));
      for (final (index, item) in items.indexed) {
        if (item == null || out.contains(item.id) || !seen.add(item.id)) {
          continue;
        }
        final candidate = batch[index];
        final because = candidate.because;
        titles.add(
          ForYouTitle(
            item: item,
            reason: because.reason,
            because: because.name,
            sources: [
              for (final source in candidate.sources) source.contribution,
            ],
          ),
        );
        if (titles.length >= maxTitles) break;
      }
    }
    return titles;
  }

  Future<MetaItemPreview?> _resolve(ForYouCandidate candidate) =>
      _resolved.putIfAbsent(
        '${candidate.key}|${candidate.suggestion.kind?.stored}',
        () => _searches.run(() async {
          final found = await resolveSuggestions(
            [candidate.suggestion],
            subjectId: '',
            search: ask.search,
          );
          return found.isEmpty ? null : found.first.item;
        }),
      );

  void _publish(List<ForYouTitle> titles) {
    if (_disposed) return;
    _worked = titles;
    notifyListeners();
  }

  /// Keeps [titles] as the row for [signature]. An [incomplete] one had a
  /// source that did not answer, and is worked out again after [retryAfter].
  Future<void> _keep(
    String signature,
    List<ForYouTitle> titles, {
    bool incomplete = false,
  }) => prefs.setForYou({
    'computedAt': now().toUtc().millisecondsSinceEpoch,
    'signature': signature,
    'titles': [for (final title in titles) title.toJson()],
    if (incomplete) 'incomplete': true,
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
