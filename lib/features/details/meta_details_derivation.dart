part of 'meta_details_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// The sources list as derived from one state of the field, one `ctx` and
/// the two layout preferences: everything `_streamSlivers` needs that costs
/// anything to compute, with the inputs it was computed from, so a build
/// whose inputs are the same objects reuses it (see `_deriveStreams`).
final class _StreamDerivation {
  const _StreamDerivation({
    required this.state,
    required this.ctx,
    required this.isSectioned,
    required this.order,
    required this.driveFiles,
    required this.driveRows,
    required this.profile,
    required this.empties,
    required this.failures,
    required this.sources,
    required this.sections,
    required this.grouped,
  });

  final MetaDetailsState state;
  final Map<String, dynamic>? ctx;
  final bool isSectioned;
  final StreamOrder order;

  /// The linked Drive files this was derived from, and the rows they became.
  ///
  /// The files are an input and are kept to be compared against the next
  /// build's ([isFor]); the rows are the output, kept because the two
  /// layouts and the television all want to know how many there are without
  /// walking the sections again.
  final List<LinkedDriveFile> driveFiles;
  final List<SourceRow> driveRows;

  /// The profile behind [ctx]; null until its first pull comes back.
  final ProfileState? profile;

  /// The groups that answered with nothing, and the addons that failed.
  final List<StreamGroup> empties;
  final List<AddonFailure> failures;

  /// What the addons agree is one source, and its merged trackers.
  final StreamSourceIndex sources;

  /// The rows of the sectioned layout, and of the grouped one; whichever
  /// [isSectioned] did not choose is empty.
  final List<StreamSection<SourceRow>> sections;
  final List<SourceGroup> grouped;

  /// Whether this was derived from exactly these inputs. The state and the
  /// `ctx` map are one object per pull ([SharedFieldScreen.ownState],
  /// [CoreFieldNotifier.value]), so identity says whether anything landed.
  ///
  /// The linked files are the exception and are compared by **value**:
  /// [LinkedDriveFiles.matching] builds a fresh list on every call, so
  /// identity would say "changed" on every build and this cache would never
  /// hit again. [LinkedDriveFile] is a value, and a match landing on one is
  /// exactly the change that has to be noticed.
  bool isFor(
    MetaDetailsState state,
    Map<String, dynamic>? ctx, {
    required bool isSectioned,
    required StreamOrder order,
    required List<LinkedDriveFile> driveFiles,
  }) =>
      identical(this.state, state) &&
      identical(this.ctx, ctx) &&
      this.isSectioned == isSectioned &&
      this.order == order &&
      listEquals(this.driveFiles, driveFiles);
}

/// What an addon is called in a list that has lost its headings: the
/// installed addon's own name, else the host its manifest URL names --
/// the same fallback the failed-addon rows use.
String _addonNameOf(ProfileState? profile, StreamGroup group) =>
    profile?.installedAddon(group.request.base)?.manifest.name ??
    group.addonLabel;

/// Whether the addon answered with something other than streams: an
/// error that is not the ordinary "this addon has nothing for this
/// video" ([LoadableError.isEmptyContent]).
bool _hasFailed(StreamGroup group) {
  final error = group.error;
  return error != null && !error.isEmptyContent;
}

/// Whether the addon has answered and had nothing: no streams, nothing
/// still on its way, and no failure (which [_hasFailed] takes first).
/// The engine's own "this addon has nothing for this video"
/// ([LoadableError.isEmptyContent]) is one of these, not a failure.
bool _answeredEmpty(StreamGroup group) =>
    group.streams.isEmpty && !group.isLoading;

/// The row for [stream] as [group] answered it, read once.
SourceRow _rowOf(ProfileState? profile, StreamGroup group, StreamInfo stream) =>
    (
      group: group,
      drive: null,
      stream: stream,
      facts: StreamFacts.of(stream, addonName: _addonNameOf(profile, group)),
      alsoFrom: const <String>[],
    );

/// One linked file as a row of the sources list.
///
/// The reading is [StreamFacts.of], the same parser every addon's stream
/// goes through, over the name Drive gave the file -- so a file whose
/// name happens to carry `1080p` is sectioned and badged like anything
/// else, and one named `holiday video 2.avi` draws no pills, which is
/// the honest rendering of a file nothing is known about.
///
/// `addonName` is [driveSourceLabel]: that slot is "where this row came
/// from", which is the sectioned layout's provenance line and the grouped
/// layout's heading, and `Google Drive` is the true answer to it.
///
/// The one thing a Drive row knows that no addon's row does is how tall
/// the video actually is: Drive measures an upload once it has processed
/// it, and [LinkedDriveFile.height] is that measurement. Where it exists
/// it decides the section and the pill, over anything the name claims —
/// see [StreamFacts.of]. Where it does not, which is the ordinary case,
/// the name is read exactly as every other row's is.
SourceRow _driveRow(LinkedDriveFile file) {
  final stream = driveSourceStream(file);
  return (
    group: null,
    drive: file,
    stream: stream,
    facts: StreamFacts.of(
      stream,
      addonName: driveSourceLabel,
      measuredHeight: file.height,
    ),
    alsoFrom: const <String>[],
  );
}

/// [rows] with every source listed once: the first row naming a source
/// stays and the later ones go, which after a sort is the best-ranked
/// instance. What survives carries the union of every listing's trackers
/// and the other addons that offered it, so the collapse hides an
/// option from nobody -- and when one addon simply repeated itself there
/// is no other addon to name and the row says nothing.
///
/// A stream with no source key at all (an unknown variant) is never
/// folded into anything; it is its own row, however many there are.
List<SourceRow> _collapse(
  List<SourceRow> rows,
  StreamSourceIndex sources,
  String Function(SourceRow row) addonOf,
) {
  final seen = <String>{};
  return [
    for (final row in rows)
      if (row.stream.sourceKey == null || seen.add(row.stream.sourceKey!))
        (
          group: row.group,
          drive: row.drive,
          stream: sources.merged(row.stream),
          facts: row.facts,
          alsoFrom: sources.alsoFrom(addonOf(row), row.stream),
        ),
  ];
}

/// Deriving the sources list from the field: the accounting of what each
/// addon answered, and the rows of both layouts.
extension _MetaDetailsDerivation on _MetaDetailsScreenState {
  /// The sources list derived from [state]: which groups answered with
  /// nothing and which failed, the source index every layout collapses on,
  /// and the sectioned and the grouped rows -- computed once per distinct
  /// set of inputs and kept ([_derived]).
  ///
  /// Deriving is a handful of regexes per stream ([StreamFacts.of]), a sort
  /// and a sectioning: a few milliseconds for three addons' worth of
  /// streams on a desktop, several times that on the box this runs on --
  /// worth caching, since this screen is rebuilt by things that change
  /// none of its inputs, such as a download's progress tick once a second
  /// for as long as anything is downloading while the screen sits under
  /// the player. The inputs are the field's state (one object per pull),
  /// the `ctx` behind the profile (the same) and the two layout
  /// preferences; what else a build reads -- the open sections, the pins
  /// in flight, the last-used source's merged trackers -- is cheap and
  /// stays in [_streamSlivers].
  _StreamDerivation _deriveStreams(
    MetaDetailsState state, {
    required bool isSectioned,
    required StreamOrder order,
    required List<LinkedDriveFile> driveFiles,
  }) {
    final ctx = _ctx?.value;
    final derived = _derived;
    if (derived != null &&
        derived.isFor(
          state,
          ctx,
          isSectioned: isSectioned,
          order: order,
          driveFiles: driveFiles,
        )) {
      return derived;
    }
    MetaDetailsScreen.debugStreamDerivations++;
    final profile = ctx == null ? null : ProfileState.fromCtx(ctx);
    final groups = state.allStreamGroups;
    // An addon that answered with an error has nothing to list, so it is
    // pulled out of the run of groups and collected below the streams
    // instead: several dead addons at once are one row there, not a wall
    // of them above the streams that do work.
    final answered = [
      for (final g in groups)
        if (!_hasFailed(g)) g,
    ];
    // An addon that answered with nothing is not a section of its own
    // either: most stream addons have nothing for most episodes, and a
    // label plus "No streams" each was most of what the list showed.
    final listed = [
      for (final g in answered)
        if (!_answeredEmpty(g)) g,
    ];
    final empties = [
      for (final g in answered)
        if (_answeredEmpty(g)) g,
    ];
    final failures = [
      for (final group in groups)
        if (_hasFailed(group))
          AddonFailure(
            transportUrl: group.request.base,
            addon: profile?.installedAddon(group.request.base),
            fallbackName: group.addonLabel,
            message: group.error?.message ?? '',
          ),
    ];
    // What the addons agree is one source, and what each of them said its
    // trackers were. Both layouts collapse on it, and the row that
    // survives plays and downloads with the union of those trackers.
    final sources = StreamSourceIndex.of([
      for (final group in listed)
        for (final stream in group.streams)
          (addon: _addonNameOf(profile, group), stream: stream),
    ]);
    // The viewer's own linked files for this video, as rows of the shape
    // an addon's answer becomes.
    //
    // **Read after the accounting above is settled, and deliberately so.**
    // [answered], [listed], [empties], [failures] and [sources] are all
    // built out of [groups] alone, so nothing a Drive file does can change
    // what this screen says about the addons: a title with a linked file
    // still reports the same four addons having had nothing, is unaffected
    // by an addon being dead, and does not count as one more thing an
    // addon offered. It is not an addon result and is not accounted as
    // one; it is one more source, which is a different sentence.
    final driveRows = [for (final file in driveFiles) _driveRow(file)];
    // The sectioned layout: every listed addon's streams together, put in
    // the chosen order ([StreamOrder], the same one for every section) and
    // then split into a collapsible section per resolution. Each row names
    // the addon it came from, since it has no heading to sit under any
    // more. Built only for the layout that shows it -- parsing every
    // stream costs a handful of regexes each.
    //
    // Sorted, then collapsed, then sectioned, in that order and for a
    // reason each: the instance of a duplicate that survives is the
    // best-ranked one rather than whichever addon was asked first, the
    // collapse is across the whole list so a source two addons described
    // differently cannot appear in two sections, and sectioning keeps the
    // order it is handed, so each section is already sorted.
    //
    // A linked Drive file is one more row in that run and nothing more: it
    // lands in the section its own name reads a resolution out of (the
    // unknown one, for a file named like a holiday video), and it takes
    // its place in the chosen order along with everything else. It is not
    // pinned to the top of its section -- the order is the chip the viewer
    // pressed, and a row that ignored it would be the list disobeying the
    // control that claims to set it.
    final sections = isSectioned
        ? sectionsByResolution(
            _collapse(
              sortedByStreamOrder(
                [
                  ...driveRows,
                  for (final group in listed)
                    for (final stream in group.streams)
                      _rowOf(profile, group, stream),
                ],
                (row) => row.facts,
                order,
              ),
              sources,
              (row) => row.facts.addonName ?? '',
            ),
            (row) => row.facts,
          )
        : const <StreamSection<SourceRow>>[];
    // The grouped layout: each addon's own ranking, with the addon's own
    // repeats collapsed. A source two addons both offered stays in both
    // groups -- the groups are the point of this layout -- and each row
    // says the other addon has it too.
    //
    // The linked Drive files are a group of their own, **first**. Their
    // heading is [driveSourceLabel] -- `Google Drive`, the same three words
    // the Remote list and the player's own description use -- because the
    // headings in this layout are display names and that is the true
    // display name of where these files are. It is not an addon and is not
    // dressed as one: it has no manifest, no host, and nothing below ever
    // resolves this heading against the profile. First, and not somewhere
    // among the addons, because the run below is the *profile's* order --
    // the order the viewer arranged their addons in -- and a thing that is
    // not an addon has no place inside it.
    final grouped = isSectioned
        ? const <SourceGroup>[]
        : [
            if (driveRows.isNotEmpty)
              (
                group: null,
                name: driveSourceLabel,
                storageLabel: driveSourceStorageLabel,
                isFromMeta: false,
                isLoading: false,
                rows: driveRows,
              ),
            for (final group in listed)
              (
                group: group,
                name: _addonNameOf(profile, group),
                storageLabel: addonStorageLabel(group),
                isFromMeta: group.isFromMeta,
                isLoading: group.isLoading,
                rows: _collapse(
                  [
                    // Read the same way the sectioned layout reads, even
                    // though this list does not *rank* by what is in a
                    // stream -- it keeps each addon's own order -- so a
                    // row shows the same badges and text whichever layout
                    // drew it. The television already pays for this read
                    // per card ([_tvSource]); paying for it once here is
                    // what makes one row look the same whichever way the
                    // list is grouped.
                    for (final stream in group.streams)
                      _rowOf(profile, group, stream),
                  ],
                  sources,
                  (_) => _addonNameOf(profile, group),
                ),
              ),
          ];
    return _derived = _StreamDerivation(
      state: state,
      ctx: ctx,
      isSectioned: isSectioned,
      order: order,
      driveFiles: driveFiles,
      driveRows: driveRows,
      profile: profile,
      empties: empties,
      failures: failures,
      sources: sources,
      sections: sections,
      grouped: grouped,
    );
  }

  /// The profile as the last derivation read it, for the places that want
  /// an addon's name outside one.
  ProfileState? get _profileNow => _derived?.profile;

  /// The linked Drive files that are [videoId] of this title, in the shape
  /// [LinkedDriveFiles.matching] already answers the question in.
  ///
  /// One call for a film and for an episode alike: [LinkedDriveMatch.isFor]
  /// reads a film's video id as its meta id, so passing the meta id for a
  /// film and `tt0903747:1:1` for an episode is the same question asked
  /// twice. A series with no episode chosen yet asks with the meta id and
  /// matches nothing, which is right -- no episode is selected, so no
  /// episode's file is offered.
  ///
  /// Empty with no pairing above this screen, and empty for a title nothing
  /// is linked to. Both draw nothing at all.
  List<LinkedDriveFile> _driveFilesFor(String videoId) =>
      _driveAccount?.files.matching(widget.id, videoId: videoId) ??
      const <LinkedDriveFile>[];
}
