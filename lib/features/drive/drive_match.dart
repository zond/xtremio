/// Working out which film or episode a linked Drive file is, from its name
/// and nothing else.
///
/// A [LinkedDriveFile] is an id, a name and a mime type. Drive has no
/// metadata worth having and the viewer is not going to type any, so the
/// name is the whole of the evidence: `The.Matrix.1999.1080p.BluRay.mkv` is
/// a film everybody knows and `ep6.avi` is nothing at all, and both of those
/// are ordinary.
///
/// **A wrong match is worse than no match.** A poster is a claim about what
/// a file *is*, and the failure being guarded against is not a missing
/// poster -- it is a real poster for the wrong film, which looks exactly
/// like a right one. `similar_resolver.dart` learned this from a model that
/// invented `The Otherside (2022)`: the catalogue answers an invented query
/// happily, with a 2008 film and a 2013 one. So the rule here is the same
/// rule as there, and reuses its pieces: a **loose title** compared on
/// [similarTitleKey], and something strict beside it. See [acceptMatch] for
/// which strict thing, and why there are two cases of it.
///
/// **Nothing here throws and nothing here reports.** A search that fails,
/// times out or answers prose is a file with no match, which is the same
/// outcome as a file whose name says nothing -- the list draws a generic
/// icon and the raw name. There is no error state for a viewer to be shown,
/// because there is nothing they could do about it and nothing has gone
/// wrong.
library;

import 'dart:async';

import '../../core/core.dart';
import '../details/stream_facts.dart';
import '../similar/similar_resolver.dart';

/// Which of Cinemeta's catalogues a name is looked for in.
///
/// One, not both, and the name chooses: a name that carries `S01E01` is an
/// episode of a series and a name that does not is a film. That is a firmer
/// claim than the one `resolveSuggestions` can make about a model's answer
/// -- a model states a kind or does not, where a season marker is written by
/// whoever made the file -- and asking both catalogues would put a film
/// named like a series episode nowhere useful anyway: a series match with no
/// episode to point at is a poster with no video under it.
String catalogueTypeFor(ReleaseIdentity identity) =>
    identity.isEpisode ? 'series' : 'movie';

/// The one Cinemeta meta that is [identity], or null when none of them is.
///
/// Both halves have to agree, and which strict half depends on what the
/// name gave:
///
///  * **The name gave a year** -- the title must match and the year must be
///    within one either way, which is the `similar_resolver.dart` rule
///    verbatim, for its reasons: festival and territory dates genuinely
///    differ by one, and two years apart is a different film. The year is
///    the discriminator, so the *first* meta that passes is taken.
///  * **The name gave no year** -- the title must match and must match
///    **exactly one** meta. With no year there is nothing else to tell two
///    candidates apart, and the honest answer to "which of these two is it"
///    is that we do not know: `The Office` answers with the American series
///    and the British one, and picking the one the catalogue happened to
///    rank first would be a coin toss drawn as a fact. Two matches is
///    therefore no match.
///
/// A name with no title at all is refused before this is reached
/// ([matchDriveFile]). A name whose title is junk -- `ep6` -- is refused
/// *here*, by the title having to be equal to a real one, which is why
/// there is no list of words that look like a title: a pre-filter guessing
/// at that would be a second parser, and the exactness of this comparison
/// already answers it.
///
/// [season] and [episode] come from the name, never from [metas]: the search
/// catalogue answers with titles and carries no videos, and the file is the
/// only thing that knows which episode it holds.
LinkedDriveMatch? acceptMatch(
  List<Map<String, dynamic>> metas,
  ReleaseIdentity identity, {
  required String type,
}) {
  final wanted = similarTitleKey(identity.title);
  if (wanted.isEmpty) return null;
  final year = identity.year;
  LinkedDriveMatch? only;
  for (final meta in metas) {
    final name = meta['name'];
    if (name is! String || similarTitleKey(name) != wanted) continue;
    // `imdb_id` in preference to `id` for the reason `_matchIn` gives: they
    // are the same string on Cinemeta, and where they are not, the imdb id
    // is the one every other addon in the app is keyed on.
    final id = meta['imdb_id'] ?? meta['id'];
    if (id is! String || id.isEmpty) continue;
    final answered = yearIn(meta['releaseInfo']);
    if (year != null && (answered == null || (answered - year).abs() > 1)) {
      continue;
    }
    final named = meta['type'];
    final candidate = LinkedDriveMatch(
      cinemetaId: id,
      type: named is String && named.isNotEmpty ? named : type,
      name: name,
      year: answered ?? year,
      season: identity.season,
      episode: identity.episode,
    );
    if (year != null) return candidate;
    // No year: a second candidate is what makes the first one a guess.
    if (only != null) return null;
    only = candidate;
  }
  return only;
}

/// What [name] matched, or null.
///
/// Null covers every way this can come to nothing, on purpose: a name with
/// no title in it, a catalogue that answered with none of it, a search that
/// threw. The caller has one thing to do about all of them.
Future<LinkedDriveMatch?> matchDriveFile(
  String name, {
  CatalogueSearch search = cinemetaSearch,
}) async {
  final identity = ReleaseIdentity.ofName(name);
  if (identity.hasNoTitle) return null;
  final type = catalogueTypeFor(identity);
  List<Map<String, dynamic>> metas;
  try {
    metas = await search(type, identity.title);
  } on Object {
    return null;
  }
  return acceptMatch(metas, identity, type: type);
}

/// Fills in the match of every linked file that has none, once each.
///
/// **Once, and off the build.** A screen that drew linked files by awaiting
/// a search would not draw until Cinemeta answered, and one that searched
/// per build would search per frame. So the screen starts a [run] and draws
/// what it has; each match is written to [DriveAccount] as it arrives, which
/// notifies, which redraws the one row that changed.
///
/// Two guards, and they are different guards:
///
///  * **The store** ([LinkedDriveFile.match]) is what keeps a *matched* file
///    from ever being searched for again, across restarts. That is the one
///    the requirement names.
///  * **[_asked]** is what keeps an *unmatched* file from being searched
///    again for the life of this run. A file nothing matches stores nothing
///    -- a null match is exactly what "no match yet" looks like, and writing
///    a sentinel would be a record claiming knowledge nobody has -- so
///    without this, every rebuild would ask again about `ep6.avi`. It is
///    memory and not preferences deliberately: a name that matched nothing
///    today may match after Cinemeta adds the title, and the next run is a
///    fair place to find out.
///
/// One at a time rather than all at once. There are a handful of files, a
/// viewer picks them by hand, and a burst of parallel requests at a
/// catalogue everybody shares buys nothing a person would notice.
final class DriveMatchRun {
  DriveMatchRun({required this.account, this.search = cinemetaSearch});

  final DriveAccount account;
  final CatalogueSearch search;

  /// The files this run has already asked about, matched or not -- **by id
  /// and name together**, so that a file linked again under a better name is
  /// asked about again rather than being remembered as hopeless. That is the
  /// only thing a viewer can do about a file nothing matched, and the note
  /// above the list tells them to do it, so it has to work in the session
  /// they are sitting in.
  ///
  /// A pair and not the two joined into one string: any separator that could
  /// be picked is a character a Drive file may have in its name.
  final Set<(String, String)> _asked = <(String, String)>{};

  /// Forgets what this run has asked about, so the next [run] asks again
  /// about every file that still has no match.
  ///
  /// **For a Reload and nothing else.** [_asked] exists to keep a rebuild
  /// from asking about `ep6.avi` once a frame, and clearing it on any other
  /// occasion would put that back. A press on Reload is different in kind:
  /// the viewer has said out loud that what is known about these files is
  /// out of date, and the answer for a file nothing matched is the one
  /// thing a reload could otherwise miss -- a renamed file re-matches
  /// because the rename dropped its match, while an unmatched file whose
  /// name did not change would be remembered as hopeless for the life of
  /// the run.
  ///
  /// A file that *did* match is unaffected either way: [run] steps over it
  /// on the store, which is the guard that outlives this one.
  void askAgain() => _asked.clear();

  /// Asks about every linked file that has no match and has not been asked.
  ///
  /// Safe to call on every build, and on a build made while a pass is still in
  /// flight -- **which is what [_asked] is for, and not only a memory of the
  /// misses.** A file is claimed there *before* the await, so a second pass
  /// walking the same list steps over everything the first one has taken and
  /// asks only about what has arrived since. There is no flag saying a pass is
  /// running, because a flag would make the overlapping call do nothing at all
  /// rather than do the new half of the work.
  ///
  /// A file with no name is refused by [matchDriveFile] rather than here: a
  /// name with no title in it is exactly what that already will not search
  /// for, and a second guard saying the same thing is a second thing to keep
  /// true.
  Future<void> run() async {
    for (final file in account.files.entries) {
      if (file.match != null) continue;
      if (!_asked.add((file.fileId, file.name))) continue;
      final match = await matchDriveFile(file.name, search: search);
      if (match == null) continue;
      await account.noteMatch(fileId: file.fileId, match: match);
    }
  }
}
