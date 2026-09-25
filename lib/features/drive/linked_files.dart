/// What the library's **Remote** option shows: every file this device has
/// linked, and what each one turned out to be.
///
/// **This is a management view, not a destination.** A matched file is going
/// to appear as a source on its own details page, beside whatever the addons
/// answered, because that is where a viewer looks for a way to play
/// something. What stays worth having permanently is the other question --
/// *what have I linked, and what did it match?* -- which nothing else on any
/// screen answers, and which is the only home a file that matched nothing
/// will ever have. So every linked file is here, matched and unmatched
/// alike, and none of them is here *because* it has nowhere else to be.
///
/// **What a press does depends on what is known, and on nothing else.**
///
///  * **Matched** -- the ordinary details screen for that title, at that
///    episode where the name gave one. Exactly what a search result does,
///    by the same route with the same arguments: two ways into one title is
///    two things to keep agreeing, and there is no flag here for the details
///    screen to read. It will not list the Drive file yet. That is the
///    follow-up's job and not something to paper over from here -- playing
///    the file directly instead would be the wrong destination made
///    permanent by being convenient.
///  * **Unmatched** -- the player, on the file itself. There is no title
///    page to send anybody to, and a screen invented for the failure case
///    would be a screen that exists because something did not work.
///
/// The matching itself is `drive_match.dart`; this starts a pass and draws
/// what is stored, which is why nothing here awaits a network call.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../widgets/focusable_tile.dart';
import '../../widgets/poster_tile.dart';
import '../details/meta_details_screen.dart';
import '../player/player_screen.dart';
import '../similar/similar_resolver.dart';
import 'drive_match.dart';

/// Every linked file as a poster tile, most recently linked first.
class LinkedDriveFilesView extends StatefulWidget {
  const LinkedDriveFilesView({
    super.key,
    this.opener = const ServerDriveFileOpener(),
    this.search = cinemetaSearch,
  });

  /// How a file is turned into something playable. A parameter for the
  /// reason `DrivePairingScreen.opener` is one: a widget test must not be
  /// pointed at the deployed server.
  final DriveFileOpener opener;

  /// How the catalogue is asked. Likewise: a test answers it with a list.
  final CatalogueSearch search;

  /// What is drawn where a poster would be for a file nothing matched, and
  /// what a test finds that row by. A **file** icon and not a film one: the
  /// poster fallback is already a strip of film
  /// ([PosterImage]'s `_PosterFallback`), and a viewer needs to be able to
  /// tell "we know nothing about this" from "the poster did not load".
  static const IconData unmatchedIcon = Icons.video_file_outlined;

  static const String emptyTitle = 'No remote files linked';

  static const String emptyHint =
      'Use the cloud button above to link a file '
      'on Google Drive; it shows up here.';

  /// The line above the list.
  ///
  /// **It earns its place because the failure is invisible otherwise.** The
  /// name is the whole of the evidence, and a file in somebody's own Drive is
  /// named however they named it -- nothing like the release names the parser
  /// was measured against. A viewer looking at a generic icon and
  /// `holiday video 2.avi` has no way to know that the file's *name* is what
  /// was searched for, and so no way to know that renaming it would fix it.
  ///
  /// Linking again rather than a reload: renaming a file in Drive does not
  /// reach this device at all -- the name is what Drive said when the file
  /// was picked -- so linking it again is what brings the new name over, and
  /// that in turn is what gets it searched for again
  /// (`DriveMatchRun._asked`). A button that re-ran the search against the
  /// old name would find the same nothing. If a reload arrives later it can
  /// be added to this sentence; nothing here promises one now.
  static const String matchedByNameNote =
      'Titles are matched from the file name. Rename a file in Drive and '
      'link it again to try once more:';

  /// Shown rather than described: somebody skimming copies the example and
  /// does not read the sentence. Both of these are walked by
  /// `drive_match_test.dart`, so a change to the parser that stopped either
  /// one parsing fails there rather than leaving this note telling a lie.
  static const List<String> nameExamples = [
    'The Matrix 1999.mkv',
    'Breaking Bad S02E11.mkv',
  ];

  @override
  State<LinkedDriveFilesView> createState() => _LinkedDriveFilesViewState();
}

class _LinkedDriveFilesViewState extends State<LinkedDriveFilesView> {
  DriveAccount? _account;
  DriveMatchRun? _matching;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final account = DriveAccountScope.maybeOf(context);
    if (account == _account) return;
    _account = account;
    _matching = account == null
        ? null
        : DriveMatchRun(account: account, search: widget.search);
    _startMatching();
  }

  /// Asks about whatever has no match yet, without being waited for.
  ///
  /// `unawaited` and not `await`: this is called from
  /// [didChangeDependencies] and from a rebuild, and a screen that waited
  /// for Cinemeta before drawing would draw nothing until a catalogue
  /// answered -- for a list whose rows are all perfectly drawable without
  /// it. Each answer is written to the account, which notifies, which
  /// redraws the row it was about. A pass already running is a no-op, so
  /// calling this per build costs one method call.
  void _startMatching() {
    final matching = _matching;
    if (matching != null) unawaited(matching.run());
  }

  /// The ordinary details screen, reached the ordinary way.
  void _openDetails(LinkedDriveMatch match) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MetaDetailsScreen(
          type: match.type,
          id: match.cinemetaId,
          videoId: match.videoId,
        ),
      ),
    );
  }

  /// Opens [file] on the embedded server and pushes the player at it.
  ///
  /// What this knows about the credential is that it does not have it:
  /// [openLinkedDriveFile] asks the account, which is the only thing that
  /// holds one, and writes a dead pairing down on the way past -- so a
  /// refusal here is a line to read and never a state to manage.
  Future<void> _play(LinkedDriveFile file) async {
    final account = _account;
    if (account == null) return;
    final opened = await openLinkedDriveFile(
      account: account,
      file: file,
      opener: widget.opener,
    );
    if (!mounted) return;
    switch (opened) {
      case DriveFilePlayable():
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: PlayerScreen.routeName),
            builder: (_) => PlayerScreen(
              stream: driveStreamJson(file: file, playable: opened),
            ),
          ),
        );
      case DriveFileRefused(:final reason):
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(
          SnackBar(content: Text(driveFailureMessage(reason))),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    // No scope above this at all is the same picture as a device nobody has
    // paired: nothing is linked, and the button above says what to do about
    // it. It is not a failure to report -- a build without the scope is a
    // build of the app that cannot link anything.
    if (account == null || account.files.isEmpty) {
      return const _NothingLinked();
    }
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) {
        _startMatching();
        final files = account.files.entries;
        if (files.isEmpty) return const _NothingLinked();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _MatchedByNameNote(),
            Expanded(child: _grid(files)),
          ],
        );
      },
    );
  }

  Widget _grid(List<LinkedDriveFile> files) => GridView.builder(
    padding: const EdgeInsets.all(12),
    // The library's own delegate, so the two lists of a viewer's own
    // titles are the same size on the same screen.
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 160,
      childAspectRatio: 0.56,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
    ),
    itemCount: files.length,
    itemBuilder: (context, index) {
      final file = files[index];
      final match = file.match;
      return _LinkedFileTile(
        file: file,
        onTap: () =>
            match == null ? unawaited(_play(file)) : _openDetails(match),
      );
    },
  );
}

/// The line above the list, and the two names that show the shape.
///
/// Quiet on purpose: it is read once and then in the way forever, so it is a
/// line of small print above a list rather than a banner or a card. The
/// examples are drawn in the monospace face the rest of the app uses for
/// literal strings, which is most of what says "this is the shape" without a
/// sentence saying it.
class _MatchedByNameNote extends StatelessWidget {
  const _MatchedByNameNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(LinkedDriveFilesView.matchedByNameNote, style: quiet),
          const SizedBox(height: 2),
          for (final example in LinkedDriveFilesView.nameExamples)
            Text(
              example,
              style: quiet?.copyWith(fontFamily: 'monospace'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

/// One linked file: its poster and matched title when it has one, a generic
/// file icon and the name Drive gave it when it does not.
///
/// The poster is asked for by id rather than kept from the search answer.
/// Cinemeta's own `poster` is a metahub URL of exactly this shape, so there
/// is nothing to be had by storing the string except a second copy of it
/// that can rot while the id cannot.
class _LinkedFileTile extends StatelessWidget {
  const _LinkedFileTile({required this.file, required this.onTap});

  final LinkedDriveFile file;
  final VoidCallback onTap;

  /// Where Cinemeta's posters live. `small` is what a 160 dp tile wants and
  /// what the library's own items carry.
  static String posterFor(String cinemetaId) =>
      'https://images.metahub.space/poster/small/$cinemetaId/img';

  /// `S1E1`, for a file whose name named an episode. Empty otherwise --
  /// including for a matched film, which has nothing more to say than its
  /// title and year.
  static String episodeLabel(LinkedDriveMatch match) =>
      match.isEpisode ? 'S${match.season}E${match.episode}' : '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final match = file.match;
    final title = match == null
        ? (file.name.isEmpty ? file.fileId : file.name)
        : match.name;
    final under = match == null
        ? driveSourceLabel
        : [
            if (match.isEpisode) episodeLabel(match),
            if (match.year != null) '${match.year}',
          ].join(' · ');
    return FocusableTile(
      onTap: onTap,
      memoryId: 'drive-${file.fileId}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: match == null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Center(
                        child: Icon(
                          LinkedDriveFilesView.unmatchedIcon,
                          size: 32,
                        ),
                      ),
                    ),
                  )
                : PosterImage(url: posterFor(match.cinemetaId)),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          if (under.isNotEmpty)
            Text(
              under,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _NothingLinked extends StatelessWidget {
  const _NothingLinked();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              LinkedDriveFilesView.emptyTitle,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              LinkedDriveFilesView.emptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
