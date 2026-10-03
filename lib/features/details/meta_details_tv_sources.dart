part of 'meta_details_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// A card that is a line of accounting rather than a source: what it
/// says and what a press on it does, and nothing of a stream's.
TvSource _accountingCard({
  required IconData icon,
  required String title,
  required List<String> lines,
  VoidCallback? onSelect,
  VoidCallback? onHold,
}) => (
  id: null,
  icon: icon,
  title: title,
  lines: lines,
  pills: const [],
  notes: const [],
  highlighted: false,
  download: null,
  downloading: false,
  onSelect: onSelect,
  onHold: onHold,
);

/// The sources on a television: the rungs below the episodes and the
/// cards in them.
extension _MetaDetailsTvSources on _MetaDetailsScreenState {
  /// The sources of the selected video as the two rows a television picks
  /// from ([TvSourceRows]), in place of the column of collapsible sections
  /// a phone and a desktop scroll.
  ///
  /// The groups are the same two the preference already chooses between --
  /// a card per resolution rung, or a card per addon -- so nothing new is
  /// stored and the order chips in the header still order inside one. What
  /// is not shared is *which* group is open: the phone remembers a set of
  /// resolutions across restarts, and this is one row at a time that Back
  /// puts away (see [_openSourceGroup]).
  ///
  /// Below them, only when no addon had anything for this title: the
  /// notice that says so ([_tvNothingFound]). What each addon did besides
  /// answer is not drawn.
  List<Widget> _tvSourceSlivers(
    MetaDetailsState state, {
    required bool isSectioned,
    required StreamOrder order,
    required List<StreamSection<SourceRow>> sections,
    required List<SourceGroup> grouped,
    required ProfileState? profile,
    required bool foundNothing,
    required bool noneYet,
    required (StreamGroup, StreamInfo)? lastUsed,
    required StreamInfo? lastUsedStream,
    required int sourceCount,

    /// How many of the rows below are linked Drive files. Counted apart
    /// from [sourceCount], which is what the addons between them offered;
    /// see [_sourcesSummary].
    required int driveCount,

    /// The same for this device's own videos.
    required int localCount,
    required StreamDownloads? downloads,

    /// Whether an installed addon offers `stream` for this title's type at
    /// all -- see [NoStreamsNotice.hasStreamAddon].
    required bool hasStreamAddon,
  }) {
    TvSource source(SourceRow row) => _tvSource(
      state,
      row,
      isSectioned: isSectioned,
      lastUsed: lastUsed?.$2,
      downloads: downloads,
    );
    final groups = <TvSourceGroup>[
      if (isSectioned)
        for (final section in sections)
          (
            label: section.label,
            count: '${section.rows.length}',
            icon: null,
            sources: [for (final row in section.rows) source(row)],
          )
      else
        for (final group in grouped)
          (
            label: group.name,
            // A group with nothing in it is here only while its answer is
            // still coming: one that settled on no streams was taken out
            // of the list above. A pill has no room to say so in words,
            // so it says nothing rather than a zero that reads as "none".
            count: group.rows.isEmpty && group.isLoading
                ? null
                : '${group.rows.length}',
            icon: null,
            sources: [for (final row in group.rows) source(row)],
          ),
    ];
    // Every addon is still answering and there is not a pill to draw yet.
    // [TvSourceRows] draws nothing for no groups, which would leave an
    // open sources rung with nothing under its header at all; the row the
    // pills will fill gets a spinner in its middle instead.
    final waiting = groups.isEmpty && state.isLoadingStreams;
    final nothing = foundNothing
        ? _tvNothingFound(
            isEpisode: state.hasVideos,
            hasStreamAddon: hasStreamAddon,
          )
        : null;
    // A rung with nothing behind its header is not drawn at all, so the
    // walk steps over it rather than stopping on a line that opens
    // nothing.
    final hasSources = groups.isNotEmpty || waiting || noneYet;
    final rung = _shownRung = _rungToOpen(
      state,
      hasLastUsed: lastUsedStream != null,
      hasSources: hasSources,
      hasAddons: nothing != null,
    );
    final sourcesOpen = rung == _DetailsRung.sources;
    // What Back has to put away, which is the row [TvSourceRows] will
    // actually draw rather than the label on its own (see
    // [_openSourceRowDrawn]) -- and only while the rung holding that row
    // is the one that is open, or a shut rung would swallow the press.
    _openSourceRowDrawn =
        sourcesOpen && groups.any((g) => g.label == _openSourceGroup);
    return [
      // The shortcut is a rung of its own above the sources, and the one
      // the screen opens for a title that has been played: it is the
      // source the viewer is most likely to want, which is why it is drawn
      // at all.
      //
      // Keyed, and so is the rung below it, because this one *appears*:
      // the engine writes the last-used source down while the player is
      // up, so the first thing a title is ever played from comes back to
      // a sliver list one longer than it left. Unkeyed, the rungs below
      // would be matched against this one's adapter, torn down and
      // rebuilt -- taking the focus node the remote was on with them, and
      // then this card, freshly built and asking for focus, would answer
      // the D-pad instead of the card the viewer left.
      if (lastUsedStream != null)
        SliverToBoxAdapter(
          key: const ValueKey('tv-last-used'),
          child: TvLadderRung(
            level: _ladderLastUsedHeader,
            label: kContinueWatchingLabel,
            // Which release it would carry on with: the one thing that
            // tells a viewer whether to press select or go and pick
            // another, and all a shut rung has room for.
            summary: releaseNameOf(
              lastUsedStream,
              addonName: _addonNameOf(profile, lastUsed!.$1),
            ),
            open: rung == _DetailsRung.continueWatching,
            onSelect: () => _selectRung(_DetailsRung.continueWatching),
            children: [
              TvLadderRow(
                level: _ladderLastUsed,
                child: TvSourceRow(
                  sources: [
                    _tvLastUsed(state, lastUsed.$1, lastUsedStream, downloads),
                  ],
                ),
              ),
            ],
          ),
        ),
      if (hasSources)
        SliverToBoxAdapter(
          key: const ValueKey('tv-source-rows'),
          child: TvLadderRung(
            level: _ladderSourcesHeader,
            label: kSourcesLabel,
            // Nothing to count yet and addons still out: say what is
            // being waited for rather than "0 from 0 addons".
            summary:
                sourceCount == 0 &&
                    driveCount == 0 &&
                    localCount == 0 &&
                    state.isLoadingStreams
                ? kLookingForStreams
                : _sourcesSummary(
                    state,
                    sources: sourceCount,
                    drive: driveCount,
                    local: localCount,
                  ),
            // The heading's own small spinner had nowhere left to go once
            // the heading became this line, and a line that says how many
            // sources there are while more are still arriving has to say
            // that too.
            trailing: !waiting && state.isLoadingStreams
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            open: sourcesOpen,
            onSelect: () => _selectRung(_DetailsRung.sources),
            children: [
              StreamsHeader(
                key: _streamsKey,
                state: state,
                sectioned: isSectioned,
                onSectionedChanged: _setStreamsSectioned,
                order: order,
                onOrderChanged: _setStreamsOrder,
                // The rung header above carries it now.
                heading: false,
                withSpinner: false,
                layoutLevel: _ladderStreamControls,
                orderLevel: _ladderStreamOrder,
              ),
              if (waiting)
                SizedBox(
                  key: const ValueKey('tv-sources-waiting'),
                  height: TvSourceRows.minSourceRowHeight(context),
                  // The spinner alone: the rung's own header line is
                  // saying what it is waiting for, and saying it twice on
                  // one screen reads as two different waits.
                  child: const Center(child: CircularProgressIndicator()),
                ),
              if (noneYet)
                const ListTile(
                  leading: Icon(Icons.touch_app_outlined),
                  title: Text('Pick an episode to see its streams'),
                ),
              TvSourceRows(
                groups: groups,
                openLabel: _openSourceGroup,
                onOpen: (label) => setState(() {
                  _openSourceGroup = label;
                  _reopenSuppressed = null;
                }),
                onFocusGroup: _focusSourceGroup,
                groupLevel: _ladderGroups,
                sourceLevel: _ladderSources,
                // A row of sources out under the pills, not a row of
                // pills with nothing under them, when this is the rung
                // the title is for.
                openOnArrival: lastUsedStream == null,
              ),
            ],
          ),
        ),
      if (_hasSimilar)
        SliverToBoxAdapter(
          key: const ValueKey('tv-more-like-this'),
          child: _tvSimilarRung(open: rung == _DetailsRung.moreLikeThis),
        ),
      if (nothing != null)
        SliverToBoxAdapter(
          key: const ValueKey('tv-nothing-found'),
          child: TvLadderRung(
            level: _ladderAddonsHeader,
            label: nothing.label,
            open: rung == _DetailsRung.addons,
            onSelect: () => _selectRung(_DetailsRung.addons),
            children: [
              TvLadderRow(
                level: _ladderAddons,
                child: TvSourceRow(sources: nothing.sources),
              ),
            ],
          ),
        ),
      const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
    ];
  }

  /// What a model says this title is like, as a rung below the sources.
  ///
  /// **Everything here is about a row that arrives late.** The answer
  /// takes seconds when it comes at all, by which time the viewer has read
  /// the screen and moved the remote, and something appearing under a
  /// viewer who is using the screen breaks it (see
  /// [_startAtTheTop] and [FocusableTile._autofocus]). Three
  /// things keep it still, and none of them is optional:
  ///
  ///  * **The header is there from the first frame.** Whether there is a
  ///    rung at all is decided by whether the title is a film or a
  ///    series, which is known before the title is drawn -- so the line appears with the
  ///    rest of the ladder and says it is looking, and the answer landing
  ///    changes the words on it and nothing else. A rung that appeared
  ///    when the answer did would push everything below it down the panel
  ///    at a moment nobody chose.
  ///  * **Nothing in it asks for the remote.** No rung does: the remote
  ///    starts on the header ([_startAtTheTop]) and gets here by being
  ///    walked here.
  ///  * **The row is the same height empty as full** ([SimilarTitlesRow]),
  ///    so even a viewer standing inside the open rung when the answer
  ///    lands sees posters replace a spinner and nothing move.
  ///
  /// And when the answer is nothing -- a model with nothing to say, or a
  /// row the guard emptied -- the rung goes away rather than standing
  /// there as a header over an empty strip.
  Widget _tvSimilarRung({required bool open}) {
    final titles = _similar;
    return TvLadderRung(
      level: _ladderSimilarHeader,
      label: kMoreLikeThisLabel,
      // Titles rather than films: the guard resolves a suggestion against
      // both catalogues, and a series that is like this film is a right
      // answer rather than a mistake to paper over in the summary.
      summary: titles == null
          ? kLookingForSimilar
          : (titles.length == 1 ? '1 title' : '${titles.length} titles'),
      // No spinner on the line, unlike the sources' header: this is not
      // what the viewer is waiting for. They came for something to watch,
      // and a second thing turning on the panel while the sources fill is
      // a race between two waits when only one of them is theirs. The
      // words say it, once.
      open: open,
      onSelect: () => _selectRung(_DetailsRung.moreLikeThis),
      children: [
        TvLadderRow(
          level: _ladderSimilar,
          child: SimilarTitlesRow(titles: titles, onOpen: _openSimilar),
        ),
      ],
    );
  }

  /// A suggestion was chosen: this screen again, for that title.
  ///
  /// Pushed rather than replaced, the way the board's tiles open a title,
  /// so Back comes back to the film the suggestion was about. Two of these
  /// screens on one field is what [SharedFieldScreen] is for.
  void _openSimilar(MetaItemPreview item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MetaDetailsScreen(type: item.type, id: item.id),
      ),
    );
  }

  /// What a shut sources rung says it holds: how many sources there are
  /// between every addon that answered, and how many addons that was.
  ///
  /// The count is of *sources* and not of listings, which is what the
  /// grouped layout would otherwise say: one release two addons both
  /// offered is one thing a viewer can watch, and the pills below it say
  /// the same by both wearing it.
  String _sourcesSummary(
    MetaDetailsState state, {
    required int sources,
    required int drive,
    required int local,
  }) {
    final addons = state.allStreamGroups
        .where((group) => group.streams.isNotEmpty)
        .length;
    final from = addons == 1 ? '1 addon' : '$addons addons';
    // The linked files are counted apart rather than added in. "4 from 2
    // addons" over a row holding three addon sources and one Drive file is
    // a lie in whichever direction it is told -- either the count is short
    // of what the row holds, or two addons are credited with a file that
    // came off the viewer's own Drive.
    return [
      '$sources from $from',
      if (drive > 0) '$drive from $driveSourceLabel',
      if (local > 0) '$local $localSourceLabel',
    ].join(' · ');
  }

  /// No addon had anything for this title: a rung of its own at the foot
  /// of the ladder, named for it, whose one card opens the addons -- on a
  /// fresh profile it is the answer to the screen, and a card to press is
  /// how the remote gets anywhere from it.
  ///
  /// It is the only thing said about the addons. Which of them failed and
  /// which had nothing used to be a rung here of its own, one card each,
  /// under every title -- a row about other people's servers at the foot
  /// of every screen, where a viewer looking for something to watch did
  /// not want it (zond, 2026-09-29). An addon that is down shows on the
  /// Addons screen's health verdict instead.
  ({String label, List<TvSource> sources}) _tvNothingFound({
    required bool isEpisode,
    required bool hasStreamAddon,
  }) {
    final explanation = NoStreamsNotice.explanationOf(
      isEpisode: isEpisode,
      hasStreamAddon: hasStreamAddon,
    );
    return (
      label: NoStreamsNotice.titleOf(isEpisode),
      sources: [
        if (hasStreamAddon)
          _accountingCard(
            icon: Icons.search_off,
            title: explanation,
            lines: const [],
          )
        else
          _accountingCard(
            icon: Icons.extension_outlined,
            title: NoStreamsNotice.addonsLabel,
            lines: [explanation],
            onSelect: _openAddons,
          ),
      ],
    );
  }

  /// One row of the sources list as a television card draws it: the whole
  /// of what the addon sent, the parse of it as pills, and a quiet line of
  /// provenance under both.
  ///
  /// **The release leads.** The engine has no field for it -- the
  /// stream's `name` is the addon and the quality, so four Torrentio
  /// cards would otherwise read "Torrentio" four times with nothing to
  /// tell them apart. [StreamPresentation.lead] derives it instead, and
  /// [StreamPresentation.rest] is everything else the addon wrote, kept
  /// on the card rather than dropped.
  ///
  /// **Nothing is dropped to save room.** The card carries every tag and
  /// note itself, with no separate readout under the row: that would
  /// describe one card at a time, while a viewer walking a row of cards
  /// is comparing them.
  ///
  /// The one thing still decided here is which of the two the pill above
  /// already says. The pills are the resolutions in the sectioned layout
  /// and the addons in the grouped one, so the notes name the addon only
  /// where the group does not.
  ///
  /// A source the player cannot open leads the notes with which kind it is
  /// instead of taking a press, so it is not a focus stop and the remote
  /// steps over it -- the disabled row, in the shape a card has.
  TvSource _tvSource(
    MetaDetailsState state,
    SourceRow row, {
    required bool isSectioned,
    required StreamInfo? lastUsed,
    required StreamDownloads? downloads,
  }) {
    final stream = row.stream;
    final group = row.group;
    final bound = downloadsFor(downloads, group);
    final read = row.facts;
    final addon =
        read.addonName ??
        (group == null ? driveSourceLabel : _addonNameOf(_profileNow, group));
    final shown = StreamPresentation.of(stream, addonName: addon);
    return (
      id: stream.sourceKey,
      icon: StreamTile.iconFor(stream.kind),
      title: shown.lead,
      lines: shown.rest,
      pills: read.pills,
      notes: [
        // What kind of source it is, which a playable card says with an
        // icon and nothing else -- an icon is a glyph a viewer has to
        // have learnt.
        stream.kind.label,
        // The release tags. Not pills: they are what a release calls
        // itself rather than a value anything is sorted or sectioned by,
        // and a dozen of them would be a wall of boxes over the words
        // they were read out of.
        ...read.tags,
        // The addon, where the group above is not already the addon, and
        // the others that offered the very same file.
        if (isSectioned) addon,
        if (row.alsoFrom.isNotEmpty) 'also from ${row.alsoFrom.join(', ')}',
      ],
      highlighted: lastUsed != null && stream.isSameSource(lastUsed),
      download: bound?.entryOf(stream),
      downloading: bound?.isPending(stream) ?? false,
      onSelect: stream.isPlayable ? () => _playRow(state, row) : null,
      onHold: bound?.remoteAction(stream),
    );
  }

  /// The last-used source as its own card: the same shortcut the vertical
  /// list draws above the sections, saying what it is on the first line
  /// and which release it is on the second.
  TvSource _tvLastUsed(
    MetaDetailsState state,
    StreamGroup group,
    StreamInfo stream,
    StreamDownloads? downloads,
  ) {
    final bound = downloads?.forGroup(group);
    return (
      id: null,
      icon: Icons.history,
      title: kContinueWithLastSource,
      lines: [
        releaseNameOf(stream, addonName: _addonNameOf(_profileNow, group)),
      ],
      // A shortcut, not a listing: the card says what pressing it does and
      // which release it would carry on with, and the row it is a
      // shortcut *to* is where that release is described.
      pills: const [],
      notes: const [],
      highlighted: true,
      download: bound?.entryOf(stream),
      downloading: bound?.isPending(stream) ?? false,
      onSelect: () => _play(state, group, stream),
      onHold: bound?.remoteAction(stream),
    );
  }
}
