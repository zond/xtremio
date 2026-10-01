import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../widgets/filter_controls.dart';
import '../../widgets/tv_ladder.dart';
import '../../widgets/remote_press.dart';
import '../downloads/download_labels.dart';
import 'stream_facts.dart';
import 'stream_sources.dart';
import 'tv_source_row.dart';

/// What [AppPrefs.openStreamAddons] stores the Drive group under.
///
/// Every other label there is a transport URL ([addonStorageLabel]), and
/// this one deliberately is not: there is no addon to name, and inventing a
/// URL-shaped one would put an addon that does not exist into the
/// preferences file. Nothing resolves a label back to an addon -- the set is
/// compared string to string and nothing else -- so a plain word is enough,
/// and it cannot collide with a URL or with a `meta:` prefixed one.
const String driveSourceStorageLabel = 'drive';

/// The same, for the group of this device's own videos in the grouped
/// layout.
const String localSourceStorageLabel = 'local';

/// The downloads binding for one source group: an addon's, recorded
/// against its request, or -- for the group with no addon behind it, the
/// linked Drive files -- one that pins with no request at all.
StreamDownloads? downloadsFor(StreamDownloads? downloads, StreamGroup? group) =>
    group == null ? downloads?.forDrive() : downloads?.forGroup(group);

/// Every stream addon has answered and none of them had anything to play.
/// With the addons xtremio installs itself that is what a series episode
/// usually looks like -- none of them serves torrents -- so the section
/// says so in as many words and offers the screen that fixes it, rather
/// than leaving a heading over nothing.
class NoStreamsNotice extends StatelessWidget {
  const NoStreamsNotice({
    super.key,
    required this.isEpisode,
    required this.hasStreamAddon,
    required this.onAddons,
  });

  /// Names what came up empty: an episode of a series, or the title.
  final bool isEpisode;

  /// Whether an installed addon offers the `stream` resource for this
  /// title's type at all. False is the fresh-install case this notice was
  /// written for; true means an addon that could have answered (Torrentio,
  /// say) simply had nothing for *this* title, which is a different and
  /// much narrower thing to say -- naming it is wrong on a Swedish series
  /// no addon covers, with a torrent addon installed and working fine on
  /// everything else.
  final bool hasStreamAddon;

  final VoidCallback onAddons;

  static const String addonsLabel = 'Add an addon';

  /// Why the list is empty when [hasStreamAddon] is false: a fresh install
  /// has no torrent addon and this is what that looks like.
  static const String noAddonExplanation =
      'None of your sources had anything to play. xtremio comes with no '
      'torrent addon, so add one and its streams show up here.';

  /// The sentence this notice says, which only claims there is no torrent
  /// addon when that is true ([hasStreamAddon] false); otherwise it says
  /// the narrower, true thing -- an installed addon answered and had
  /// nothing for this one title.
  static String explanationOf({
    required bool isEpisode,
    required bool hasStreamAddon,
  }) {
    if (!hasStreamAddon) return noAddonExplanation;
    final what = isEpisode ? 'episode' : 'film';
    return 'None of your addons had a stream for this $what.';
  }

  /// What came up empty: an episode of a series, or the title.
  static String titleOf(bool isEpisode) =>
      isEpisode ? 'No streams for this episode' : 'No streams for this title';

  String get title => titleOf(isEpisode);

  String get explanation =>
      explanationOf(isEpisode: isEpisode, hasStreamAddon: hasStreamAddon);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.search_off, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(explanation, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          if (!hasStreamAddon) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: onAddons,
                icon: const Icon(Icons.extension_outlined),
                label: const Text(addonsLabel),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What the stream section says between a tap on an episode and the
/// engine's answer.
const String kLookingForStreams = 'Looking for streams…';

/// The shortcut to the source this title was last played from, above the
/// sections on a phone and its own card on a television.
const String kContinueWithLastSource = 'Continue with last source';

/// What the rung holding the last-used source is called when it is shut.
const String kContinueWatchingLabel = 'Continue watching';

/// What the rung holding the sources is called when it is shut. "Sources"
/// and not "Streams": a television's rung is a row of releases to pick
/// from, and the word the rest of this screen's TV code uses for one.
const String kSourcesLabel = 'Sources';

/// What the rung holding the season and its episodes is called.
const String kEpisodesLabel = 'Episodes';

/// What each of the header's two layout chips reads. The selected one is
/// the layout on screen, which is why both are worded as states rather
/// than as actions: a chip that says what it would do reads as a lie the
/// moment it is the one already chosen.
const String kStreamsSectionedLabel = 'Sectioned by resolution';
const String kStreamsGroupedLabel = 'Grouped by addon';

/// The key on one resolution section's header.
///
/// A test (and anything else looking for a heading) has to be able to say
/// *which* section it means, and the label alone cannot: a 1080p row badges
/// itself `1080p` too, so the text is on the heading and on every row under
/// it.
Key streamSectionKey(StreamResolution? resolution) =>
    ValueKey('streams-section-${resolution?.label ?? 'unknown'}');

/// The label [AppPrefs.openStreamAddons] stores one addon group under: the
/// addon's transport URL, which is the identity the profile, the
/// failed-addon rows and a pin all key on already.
///
/// Not the heading: that is a name, and a name is neither unique (two
/// addons may call themselves the same thing) nor stable (a manifest
/// renames itself and the group a viewer opened would come back shut). The
/// streams a *meta* addon attached to the video are a group of their own,
/// under a heading of their own ("From ..."), and get a label of their own
/// -- the same addon can answer both as the meta addon and as a stream
/// addon, and the two groups open and close separately.
String addonStorageLabel(StreamGroup group) =>
    group.isFromMeta ? 'meta:${group.request.base}' : group.request.base;

/// The key on one addon group's header, where [storageLabel] is what
/// [addonStorageLabel] made of the group -- the addon's transport URL.
///
/// By the stored label and not by the heading, for the reason that label
/// exists: a heading is a name, two addons may share one, and a test that
/// tapped a name would be tapping whichever group came first.
Key streamAddonKey(String storageLabel) =>
    ValueKey('streams-addon-$storageLabel');

class StreamsHeader extends StatelessWidget {
  const StreamsHeader({
    super.key,
    required this.state,
    this.video,
    this.isLoading = false,
    this.sectioned = true,
    this.onSectionedChanged,
    this.order = StreamOrder.peersPerSize,
    this.onOrderChanged,
    this.withSpinner = true,
    this.heading = true,
    this.layoutLevel,
    this.orderLevel,
  });

  /// Whether the heading draws its own title and the line about which
  /// episode it is.
  ///
  /// False on a television, where the sources are a rung of a collapsing
  /// ladder and the rung's header line already says what this is and how
  /// much of it there is. What is left here is the chips, which are the
  /// two choices about the list rather than a heading over it.
  final bool heading;

  /// Which rungs of the screen's [TvLadder] the heading's two chip rows
  /// are, or null off a television and in the layouts that have no ladder.
  ///
  /// Two rungs and not one: they are drawn one above the other, so a
  /// single rung would mean a press down from the layout chips left the
  /// heading entirely and neither row could be reached from the other.
  final int? layoutLevel;
  final int? orderLevel;

  /// Puts one line of the heading on a rung, when there is a ladder.
  ///
  /// Select on a chip picks it and then moves down, as it does on the
  /// rows where landing already chooses: a viewer who has chosen how the
  /// sources are cut or ordered is on the way to the sources.
  static Widget _rung(int? level, Widget child) => level == null
      ? child
      : TvLadderRow(level: level, advanceOnSelect: true, child: child);

  final MetaDetailsState state;

  /// Whether the heading wears its small spinner while addons are still
  /// answering. False when the list below is drawing a larger one of its
  /// own, so the screen never spins in two places at once.
  final bool withSpinner;

  /// Whether the list below is the one cut into resolution sections,
  /// rather than one section per addon.
  final bool sectioned;

  /// Picks the layout; null draws no layout chips at all.
  final ValueChanged<bool>? onSectionedChanged;

  /// What order the streams inside each section are in. Only the sectioned
  /// layout has such an order to choose -- the grouped one is the addons'
  /// own ranking, which is the whole point of it -- so the chips are drawn
  /// only there.
  final StreamOrder order;

  /// Picks that order; null draws no chips.
  final ValueChanged<StreamOrder>? onOrderChanged;

  /// The episode the section is about; null takes the state's selection.
  /// A tap that has not been answered yet names the tapped episode here,
  /// which the state does not know about.
  final VideoInfo? video;

  /// Spins even when no addon group is loading yet (a tap whose `Load` has
  /// not come back).
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final video = this.video ?? state.selectedVideo;
    final meta = state.meta;
    final subtitle = video != null && meta != null && video.id != meta.id
        ? [
            if (video.seasonEpisodeLabel.isNotEmpty) video.seasonEpisodeLabel,
            if (video.title.isNotEmpty) video.title,
          ].join(' · ')
        : null;
    final onOrderChanged = this.onOrderChanged;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (heading)
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Streams',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      if (subtitle != null)
                        Text(subtitle, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                if (withSpinner && (isLoading || state.isLoadingStreams))
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          // How the list is cut, as a choice rather than as a switch: two
          // chips reading the two layouts, the selected one being what is
          // on screen. Above the order chips because it is the larger
          // decision of the two -- an order only exists inside the
          // sectioned layout -- and packed left like every other row here.
          if (onSectionedChanged != null)
            _rung(
              layoutLevel,
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: FilterChips<bool>(
                  options: [
                    FilterOption(
                      label: kStreamsSectionedLabel,
                      selected: sectioned,
                      request: true,
                    ),
                    FilterOption(
                      label: kStreamsGroupedLabel,
                      selected: !sectioned,
                      request: false,
                    ),
                  ],
                  onSelect: onSectionedChanged!,
                ),
              ),
            ),
          if (sectioned && onOrderChanged != null)
            _rung(
              orderLevel,
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: FilterChips<StreamOrder>(
                  options: [
                    for (final choice in StreamOrder.values)
                      FilterOption(
                        label: choice.label,
                        selected: choice == order,
                        request: choice,
                      ),
                  ],
                  onSelect: onOrderChanged,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One group of the **grouped by addon** layout: an addon's answer, or the
/// linked Drive files, which are not an addon's answer and cannot be
/// described as one.
///
/// A record and not just a [StreamGroup] paired with its rows, because a
/// group with no addon behind it -- the linked Drive files -- has no
/// [StreamGroup] to read its name, its storage label or whether it is
/// still answering off of; the record supplies each of those directly.
typedef SourceGroup = ({
  /// The addon group, or null for the linked Drive files. Null is what says
  /// there is no addon request to record a pin against and no addon health
  /// to be affected by; a Drive file downloads all the same, with none
  /// recorded ([downloadsFor]).
  StreamGroup? group,

  /// The heading, as a viewer reads it: the addon's own name, or
  /// [driveSourceLabel].
  String name,

  /// What [AppPrefs.openStreamAddons] remembers this group's open state
  /// under -- the addon's transport URL, or [driveSourceStorageLabel].
  String storageLabel,

  /// Whether the heading says "From ..." -- streams a *meta* addon attached
  /// to the video itself. Never true of the Drive group.
  bool isFromMeta,

  /// Whether the answer is still on its way, which is what a group with no
  /// rows draws a spinner for. Never true of the Drive group: the files are
  /// read off the preferences and are either there or not.
  bool isLoading,
  List<SourceRow> rows,
});

/// One row of the sources list, in either layout: the stream as it will be
/// played -- with the trackers every listing of it named -- the addon group
/// it came from (a download records the request its stream came from, so
/// the group has to travel with it), what could be read out of it -- in
/// either layout, so one row looks the same whichever way the list is
/// grouped -- and the other addons that offered the same source.
/// A row with no [group] is a linked Google Drive file and carries [drive]
/// instead: the two are exactly the two kinds of row, which is why a null
/// check on either settles it. [stream] is then the placeholder
/// [driveSourceStream] builds -- enough to read, section and draw the row,
/// and never something a player is handed; the press goes through
/// [_MetaDetailsScreenState._playRow] to the real open.
typedef SourceRow = ({
  StreamGroup? group,
  LinkedDriveFile? drive,
  LocalMediaFile? local,
  StreamInfo stream,
  StreamFacts facts,
  List<String> alsoFrom,
});

/// What a stream tile knows about offline downloads: the entry for its
/// stream if the registry has one, whether a pin for it is in flight, how
/// to start one and how to drop one. Bound to the addon group the tile sits
/// in, because a pin records the request its stream came from.
final class StreamDownloads {
  const StreamDownloads({
    required this.videoEntry,
    required this.isPending,
    required this.onDownload,
    required this.onDelete,
    this.group,
    this.drive = false,
  });

  /// The download of the video these tiles belong to, from any source.
  final DownloadView? Function() videoEntry;
  final bool Function(StreamInfo stream) isPending;

  /// Starts a download; the [StreamGroup] is null for a linked Drive file,
  /// which has no addon request to record.
  final void Function(StreamGroup? group, StreamInfo stream) onDownload;

  /// Removes one, after asking what becomes of the file. Unlike a download
  /// this needs no group: an entry names the stream it was taken from.
  final void Function(DownloadView entry) onDelete;

  /// The addon group; null until [forGroup] binds one, which is when a tile
  /// can offer to download at all -- or until [forDrive] says there is none
  /// to bind.
  final StreamGroup? group;

  /// Whether this binding is the linked Drive files': a null [group] that
  /// nevertheless pins, as opposed to the unbound reading a tile makes
  /// before it knows which group it is in.
  final bool drive;

  StreamDownloads forGroup(StreamGroup group) => StreamDownloads(
    videoEntry: videoEntry,
    isPending: isPending,
    onDownload: onDownload,
    onDelete: onDelete,
    group: group,
  );

  StreamDownloads forDrive() => StreamDownloads(
    videoEntry: videoEntry,
    isPending: isPending,
    onDownload: onDownload,
    onDelete: onDelete,
    drive: true,
  );

  /// The download taken from [stream] itself, if there is one.
  DownloadView? entryOf(StreamInfo stream) {
    final entry = videoEntry();
    return entry != null && entry.stream.isSameSource(stream) ? entry : null;
  }

  /// Starts the download of [stream]; null when the server has nothing to
  /// pin (a stream that is not a file it keeps) or one is already on its
  /// way.
  VoidCallback? starter(StreamInfo stream) {
    final group = this.group;
    // A torrent, a plain web link or a linked Drive file: all three are
    // files the server keeps (a torrent in its piece store, the other two
    // in its proxy cache -- see the server's `proxy_downloads`). YouTube
    // and external streams open other apps and hold no bytes of ours.
    if (!_downloadable(stream)) return null;
    if (group == null && !drive) return null;
    if (isPending(stream)) return null;
    return () => onDownload(group, stream);
  }

  static bool _downloadable(StreamInfo stream) =>
      stream.kind == StreamKind.torrent ||
      (stream.kind == StreamKind.url &&
          (stream.url?.startsWith('http://') == true ||
              stream.url?.startsWith('https://') == true ||
              isDriveStream(stream)));

  /// What a hold on the source [stream] is drawn on does about the copy on
  /// the device, for a remote that cannot press the button.
  ///
  /// Directional traversal skips a node inside the focused one's rect, and
  /// the button is inside the row or the card the remote activates as a
  /// whole, so on a television it can be looked at and never reached. A
  /// long press -- hold select, or the remote's menu key -- is the "more
  /// options" gesture everywhere else in the app, and here there is
  /// exactly one option: whatever the button beside the play arrow would
  /// do. Null while there is nothing to do (a stream the server cannot
  /// keep, a pin in flight, a download still arriving), which leaves a
  /// hold meaning what it meant before -- a tap on release.
  VoidCallback? remoteAction(StreamInfo stream) {
    if (isPending(stream)) return null;
    final entry = entryOf(stream);
    if (entry == null) return starter(stream);
    return switch (entry.state) {
      DownloadState.complete => () => onDelete(entry),
      DownloadState.error || DownloadState.gone => starter(stream),
      _ => null,
    };
  }
}

/// One resolution's worth of the sources list: a header that says what it
/// holds whether or not it is open, and the streams under it when it is.
///
/// A collapsed header is not a placeholder: it says how many streams are
/// folded away and the best swarm among them ([StreamSection.summary]), so
/// a 2160p section with one dead torrent in it is told from a healthy one
/// without opening either. It is an ordinary [ListTile] with an `onTap`,
/// which is what makes a remote able to reach it and open it: a television
/// walks the pane by focusable nodes, and a header that could not take
/// focus would put every section below the first one out of reach.
class ResolutionSectionSliver extends StatelessWidget {
  const ResolutionSectionSliver({
    super.key,
    required this.section,
    required this.expanded,
    required this.onExpand,
    required this.lastUsed,
    required this.onPlay,
    this.downloads,
  });

  final StreamSection<SourceRow> section;
  final bool expanded;
  final VoidCallback onExpand;

  /// The stream pinned as "Continue with last source", highlighted here too.
  final StreamInfo? lastUsed;
  final ValueChanged<SourceRow> onPlay;

  /// The downloads, when there is a client above this screen. Bound to each
  /// row's own group, since a pin records the request its stream came from.
  final StreamDownloads? downloads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: ListTile(
            key: streamSectionKey(section.resolution),
            leading: Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              section.label,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            subtitle: Text(section.summary),
            onTap: onExpand,
          ),
        ),
        if (expanded)
          SliverList.builder(
            itemCount: section.rows.length,
            itemBuilder: (context, index) {
              final row = section.rows[index];
              final lastUsed = this.lastUsed;
              return StreamTile(
                stream: row.stream,
                facts: row.facts,
                alsoFrom: row.alsoFrom,
                highlighted:
                    lastUsed != null && row.stream.isSameSource(lastUsed),
                onTap: row.stream.isPlayable ? () => onPlay(row) : null,
                downloads: downloadsFor(downloads, row.group),
              );
            },
          ),
      ],
    );
  }
}

/// One addon's answer: a header that says whose it is and how much is in
/// it, the streams under it when it is open, and a spinner while they are
/// still on their way.
///
/// Collapsible for the reason the resolution sections are: with several
/// addons installed the open groups ran one after another for screens, and
/// what a viewer wanted was the one addon they trust. A closed header
/// still says how many streams are folded away -- not how healthy they
/// are, the way [ResolutionSectionSliver] does: this list is each addon's
/// own ranking, and a summary of what is inside would be summarising an
/// order the addon chose rather than one this screen did.
///
/// Only groups with something to show reach here: an addon that failed or
/// answered with nothing is not listed at all.
class StreamGroupSliver extends StatelessWidget {
  const StreamGroupSliver({
    super.key,
    required this.group,
    required this.expanded,
    required this.onExpand,
    required this.lastUsed,
    required this.onPlay,
    this.downloads,
  });

  /// The group and everything drawing it needs: its heading, the label its
  /// open state is stored under, and its rows.
  ///
  /// The heading is a **name** -- the addon's own, out of its manifest, or
  /// `Google Drive` for the viewer's own linked files. `group.addonLabel`,
  /// the host of the manifest URL, would read a list of "Torrentio",
  /// "Comet" and "MediaFusion" as "torrentio.strem.fun",
  /// "comet.elfhosted.com" and "mediafusion.elfhosted.com" instead: the
  /// hosting arrangement rather than the addon, with three of them sharing
  /// a domain looking like one thing. That is also why the Drive group is
  /// headed with three words a viewer reads rather than with anything
  /// URL-shaped: there is no addon here at all, and the heading has to say
  /// what is true.
  final SourceGroup group;

  /// Whether the rows are on screen. Remembered across titles and restarts
  /// in [AppPrefs.openStreamAddons]; with nothing remembered every group is
  /// closed.
  final bool expanded;
  final VoidCallback onExpand;

  /// The stream pinned as "Continue with last source", highlighted here too.
  final StreamInfo? lastUsed;
  final ValueChanged<SourceRow> onPlay;

  /// The downloads, when there is a client above this screen
  /// ([downloadsFor]).
  final StreamDownloads? downloads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = group.rows;
    final label = group.isFromMeta ? 'From ${group.name}' : group.name;
    // Nothing yet, as opposed to nothing at all: a group that settled on
    // no streams is never listed here at all, so the label with a spinner
    // under it can only mean the answer is still coming.
    final waiting = rows.isEmpty && group.isLoading;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: ListTile(
            key: streamAddonKey(group.storageLabel),
            leading: Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            // A group still answering has nothing folded away yet, so it
            // counts nothing and says so with the spinner below instead.
            subtitle: waiting
                ? null
                : Text(
                    rows.length == 1 ? '1 stream' : '${rows.length} streams',
                  ),
            onTap: onExpand,
          ),
        ),
        // Whatever the memory says: an answer still on its way is not
        // something the viewer closed, and a spinner nobody can see reads
        // as an addon that was never asked.
        if (waiting)
          const SliverToBoxAdapter(
            child: ListTile(
              dense: true,
              leading: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text(kLookingForStreams),
            ),
          ),
        if (expanded)
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              final stream = row.stream;
              final lastUsed = this.lastUsed;
              return StreamTile(
                stream: stream,
                facts: row.facts,
                headedByAddon: true,
                alsoFrom: row.alsoFrom,
                highlighted: lastUsed != null && stream.isSameSource(lastUsed),
                onTap: stream.isPlayable ? () => onPlay(row) : null,
                downloads: downloads,
              );
            },
          ),
      ],
    );
  }
}

/// One stream: the line that names what a press would start, the whole of
/// what the addon wrote under it, the parse of that as chips, a download
/// affordance for a torrent, and a play affordance (or the kind of source
/// when the player cannot open it).
///
/// **The row carries the addon's text entire.** The lines beyond the
/// headline are lines of their own, in the order the addon wrote them
/// ([StreamPresentation.rest]) -- a pack's collection line, the `⚙️` it was
/// indexed on, the flags saying which dubs are on it -- and the only thing
/// taken out of them is what the line the row is headed with has already
/// said.
///
/// **And none of it is cut.** Not the release, not the addon's lines, not
/// the addon's name: the list scrolls, so a row is as tall as what is on
/// it. A television card is the one that cannot do that ([TvSourceCard]).
///
/// The chips are the parse of that text drawn under it ([StreamFacts.pills]),
/// which means a `💾 1.51 GB` and a `1.51 GB` chip are on the same row on
/// purpose: it is the one place a viewer can see the reading the list is
/// ordered by agree with what the addon actually said.
class StreamTile extends StatelessWidget {
  const StreamTile({
    super.key,
    required this.stream,
    required this.onTap,
    this.highlighted = false,
    this.leadingIcon,
    this.titleOverride,
    this.downloads,
    this.facts,
    this.alsoFrom = const [],
    this.headedByAddon = false,
  });

  final StreamInfo stream;

  /// The other addons that offered this very source, when more than one
  /// did. The row is one of them (the best-ranked, or the one whose group
  /// this is), and this is how it says the others are not missing but the
  /// same thing again. Empty says nothing at all -- including for a source
  /// one addon listed twice, which is the addon repeating itself.
  final List<String> alsoFrom;

  /// What was read out of the stream: a badge for each thing that is
  /// actually known, and an unknown gets no badge rather than a
  /// placeholder.
  ///
  /// Both lists pass one. Null is the "continue with the last source"
  /// row, which says what it is instead of what it holds.
  final StreamFacts? facts;

  /// Whether the heading above this row already names the addon, as the
  /// grouped list's does.
  ///
  /// The two lists show the same row from the same reading, and differ in
  /// exactly one thing: which fact the heading has already said. The
  /// sectioned list is headed by a resolution, so the row names the addon
  /// under the release; the grouped list is headed by the addon, so it
  /// does not say it twice. Everything else -- the release, the badges --
  /// is the same either way, and that is the point of the flag.
  final bool headedByAddon;
  final VoidCallback? onTap;
  final bool highlighted;
  final IconData? leadingIcon;
  final String? titleOverride;

  /// The offline downloads, when there is a client above this screen.
  final StreamDownloads? downloads;

  @override
  Widget build(BuildContext context) {
    final hints = StreamHints.of(stream);
    final facts = this.facts;
    // The release, not the addon. `stream.title` is `name ?? description`,
    // which for the addons people actually install is their own name and a
    // quality -- "Torrentio 4k" -- so a phone showed the release nowhere in
    // the flat list and only as a subtitle in the grouped one. The
    // television was given [releaseNameOf] when its cards were rebuilt;
    // this is the same derivation, in the list the phone draws.
    final shown = StreamPresentation.of(stream, addonName: facts?.addonName);
    final title = titleOverride ?? shown.lead;
    // A row whose whole name is the hint ("1080p", which is all some
    // addons call a stream) needs no badge saying it again. The badges
    // come from [StreamFacts.pills], or [StreamHints.chips] when there are
    // no facts, so this is checked against what the row is actually
    // headed with -- either source can repeat the title just as readily,
    // and a row reading "1080p / 1080p / 2 GB" is what it looks like when
    // nobody checks.
    // The kept release says so where the row is read, not only in the
    // trailing button: a picker with five releases and one bin icon was a
    // puzzle ("which one is the download?").
    final kept = downloads?.entryOf(stream)?.isComplete == true;
    final chips = [
      if (kept) kDownloadedChipLabel,
      for (final chip in facts?.pills ?? hints.chips)
        if (chip.toLowerCase() != title.toLowerCase()) chip,
    ];
    // The addon's own lines under the one the row is headed with. The
    // "continue" row has no reading behind it and is headed with what it
    // does rather than with a release, so it says what the source calls
    // itself and nothing more.
    final said = facts == null ? [stream.title] : shown.rest;
    // Which fact the heading above has not already said.
    final description = facts == null || headedByAddon ? null : facts.addonName;
    final isTv = DeviceScope.isTv(context);
    final alsoFrom = this.alsoFrom.isEmpty
        ? null
        : alsoFromLabel(this.alsoFrom);
    final quiet = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final lines =
        said.length +
        [description, alsoFrom].nonNulls.length +
        (chips.isEmpty ? 0 : 1);
    final tile = ListTile(
      enabled: onTap != null,
      selected: highlighted,
      leading: Icon(leadingIcon ?? iconFor(stream.kind)),
      // Nothing on this row is cut short. A release name is read token by
      // token -- the resolution, the source, the codec, the group -- and
      // `The.Matrix.1999.2160p.MAX.WEB-DL.DV.HDR.ENG.LATIN…` says less
      // about which file it is than the whole of it does. The list scrolls
      // and a row may be any height, so the text wraps and the row grows;
      // the television, whose row is a strip of fixed-height cards with no
      // scroll to grow into, keeps its caps ([TvSourceCard]).
      title: Text(title),
      isThreeLine: lines > 1,
      subtitle: lines == 0
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Whole, and not squeezed onto one line: a stats line, a
                // collection a file came out of and a line of flags are
                // three different things, and the addon put them on three
                // lines because they are.
                for (final line in said) Text(line),
                if (description != null) Text(description, style: quiet),
                if (alsoFrom != null) Text(alsoFrom, style: quiet),
                if (chips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [for (final chip in chips) _HintChip(chip)],
                    ),
                  ),
              ],
            ),
      trailing: _trailing(context),
      onTap: onTap,
    );
    final filename = hints.filename;
    final withTooltip = filename == null
        ? tile
        : Tooltip(message: filename, child: tile);
    if (!isTv) return withTooltip;
    return RemotePress(
      onTap: onTap,
      onLongPress: downloads?.remoteAction(stream),
      child: withTooltip,
    );
  }

  /// The download affordance (when there is one) beside the play one.
  Widget _trailing(BuildContext context) {
    final theme = Theme.of(context);
    // A YouTube stream opens in the YouTube app, not here: the icon says it
    // leaves ([StreamInfo.youtubeUrl]).
    final play = onTap != null
        ? Icon(
            stream.kind == StreamKind.youtube
                ? Icons.open_in_new
                : Icons.play_arrow,
          )
        : Text(stream.kind.label, style: theme.textTheme.labelSmall);
    final download = _downloadAffordance(context);
    if (download == null) return play;
    return Row(mainAxisSize: MainAxisSize.min, children: [download, play]);
  }

  /// What the download side of the tile shows: a button to start one, a
  /// ring while it arrives, a button that deletes it once it is on the
  /// device, and the error as a button that pins again. Nothing at all for
  /// a stream the server cannot keep (not a torrent, a link or a Drive
  /// file) or with no client above.
  Widget? _downloadAffordance(BuildContext context) {
    final downloads = this.downloads;
    if (downloads == null) return null;
    if (downloads.isPending(stream)) {
      return const _DownloadIndicator(
        tooltip: kDownloadStartingTooltip,
        progress: null,
      );
    }
    final entry = downloads.entryOf(stream);
    final start = downloads.starter(stream);
    if (entry == null) {
      if (start == null) return null;
      // The same button whether or not the video is kept from another
      // release: pressing it where one is kept asks first, and the question
      // says what goes (`_download`). A swap icon here said it in a way
      // nobody could read off a television, where tooltips do not show.
      return IconButton(
        tooltip: kDownloadTooltip,
        icon: const Icon(Icons.download_outlined),
        onPressed: start,
      );
    }
    return switch (entry.state) {
      // The finished state is a button, not a tick: the picker that took
      // the download is where the user is when they decide they do not
      // want it any more, and a tick there would say the same thing while
      // doing nothing. It keeps the tick's primary colour, so the row
      // still reads as "this one is on the device".
      DownloadState.complete => IconButton(
        tooltip: kDownloadDeleteTooltip,
        color: Theme.of(context).colorScheme.primary,
        icon: const Icon(Icons.delete_outline),
        onPressed: () => downloads.onDelete(entry),
      ),
      // The same button for a download that stopped and one whose pieces
      // are gone: both are "press to have this file again", and the
      // tooltip is what tells them apart.
      DownloadState.error => IconButton(
        tooltip: kDownloadRetryTooltip,
        icon: const Icon(Icons.error_outline),
        onPressed: start,
      ),
      DownloadState.gone => IconButton(
        tooltip: kDownloadGoneTooltip,
        icon: const Icon(Icons.error_outline),
        onPressed: start,
      ),
      // A ring at 0 rather than a spinner: a queued download whose length
      // is not known yet is still a fraction of nothing, and an
      // indeterminate spinner would say "working" about a file nobody is
      // sending yet.
      _ => _DownloadIndicator(
        tooltip: downloadStateLabel(entry),
        progress: entry.progress ?? 0,
      ),
    };
  }

  static IconData iconFor(StreamKind kind) => switch (kind) {
    StreamKind.torrent || StreamKind.magnet => Icons.cloud_download_outlined,
    StreamKind.url => Icons.link,
    StreamKind.youtube => Icons.smart_display_outlined,
    StreamKind.external => Icons.open_in_new,
    StreamKind.playerFrame => Icons.web,
    StreamKind.archive => Icons.folder_zip_outlined,
    StreamKind.unknown => Icons.help_outline,
  };
}

/// The non-pressable half of the download affordance: a progress ring, or
/// a spinner while there is no fraction to show, padded to the size of the
/// [IconButton] it stands in for so the tile does not jump when the state
/// changes.
class _DownloadIndicator extends StatelessWidget {
  const _DownloadIndicator({required this.tooltip, this.progress});

  final String tooltip;

  /// `0..1` of the file; null spins.
  final double? progress;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2, value: progress),
      ),
    ),
  );
}

class _HintChip extends StatelessWidget {
  const _HintChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}
