part of 'meta_details_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// The label [AppPrefs.openStreamSections] stores one section under: a
/// resolution's own [StreamResolution.label], or `'unknown'` for the
/// section nothing could be read a resolution from -- the same word
/// [streamSectionKey] uses for that section's widget key.
String _sectionStorageLabel(StreamResolution? resolution) =>
    resolution?.label ?? 'unknown';

/// The sources list on a phone and a desktop, and the layout choices it
/// remembers.
extension _MetaDetailsStreams on _MetaDetailsScreenState {
  /// The streams for the selected video, the meta addon's own first. The
  /// engine lists every addon it asked from the moment of the request (as
  /// `Loading` groups), so the header's small spinner is the only loading
  /// indicator needed once they are in; an empty list means no addon was
  /// asked. Between a tap and that first state there is nothing at all to
  /// list, and the section says so where the tap can see it.
  List<Widget> _streamSlivers(MetaDetailsState state, MetaItem meta) {
    // Nothing is open until the rows below say otherwise: every path out
    // of here that is not [_tvSourceSlivers] draws no row at all.
    _openSourceRowDrawn = false;
    final isSectioned = _prefs?.streamsSectioned ?? true;
    final order = _prefs?.streamsOrder ?? StreamOrder.peersPerSize;
    final lastUsed = state.lastUsedStream;
    final groups = state.allStreamGroups;
    final videoId = state.streamPath?.id ?? meta.id;
    final driveFiles = _driveFilesFor(videoId);
    final localFiles = _localFilesFor(videoId);
    final noneYet =
        state.hasVideos && state.streamPath == null && groups.isEmpty;
    // Every addon that was asked has answered and none of them offered
    // anything the player can open. On a fresh profile that is the normal
    // answer rather than a fault, so it is explained rather than left as
    // an empty list under a heading.
    //
    // A linked Drive file makes this false, notice included: the notice
    // reads "None of your sources had anything to play", and with a file
    // of the viewer's own listed above it that sentence is not true --
    // one of their sources has exactly this title, and the row to press
    // is on the screen saying so.
    final foundNothing =
        state.streamPath != null &&
        groups.isNotEmpty &&
        !state.isLoadingStreams &&
        lastUsed == null &&
        driveFiles.isEmpty &&
        localFiles.isEmpty &&
        state.playableStreams.isEmpty;
    // A tapped episode whose streams have not arrived: everything below is
    // still the previous selection's, so show none of it.
    if (_isAwaitingStreams(state)) {
      return [
        SliverToBoxAdapter(
          child: StreamsHeader(
            key: _streamsKey,
            state: state,
            video: meta.videoById(_awaitingVideoId!),
            isLoading: true,
            sectioned: isSectioned,
            onSectionedChanged: _setStreamsSectioned,
            order: order,
            onOrderChanged: _setStreamsOrder,
          ),
        ),
        const SliverToBoxAdapter(
          child: ListTile(
            leading: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: Text(kLookingForStreams),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ];
    }
    // On a TV focus starts on the stream the user most likely wants: the
    // last used source, else the first playable one. Autofocus only takes
    // when nothing on the screen is focused yet, so streams arriving after
    // the user has moved on leave focus where it is.
    final isTv = DeviceScope.isTv(context);
    final derived = _deriveStreams(
      state,
      isSectioned: isSectioned,
      order: order,
      driveFiles: driveFiles,
      localFiles: localFiles,
    );
    final profile = derived.profile;
    final sources = derived.sources;
    final sections = derived.sections;
    final grouped = derived.grouped;
    final openSections = _visibleOpenSections(sections);
    final openAddons = _rememberedOpenAddons();
    // The shortcut is the same source as one of the rows below, so it is
    // handed the same merged trackers; nothing else about it changes.
    final lastUsedStream = lastUsed == null
        ? null
        : sources.merged(lastUsed.$2);
    if (isTv && lastUsedStream != null) _takeTheRemoteToTheLastUsed();
    final downloads = _downloadsClient == null
        ? null
        : StreamDownloads(
            videoEntry: () => _videoDownload(videoId),
            isPending: (stream) =>
                _pending.contains(_streamKey(videoId, stream)),
            onDownload: (group, stream) =>
                _download(state, meta, group, stream),
            onDelete: _deleteDownload,
          );
    if (isTv) {
      return _tvSourceSlivers(
        state,
        isSectioned: isSectioned,
        order: order,
        sections: sections,
        grouped: grouped,
        profile: profile,
        foundNothing: foundNothing,
        noneYet: noneYet,
        lastUsed: lastUsed,
        lastUsedStream: lastUsedStream,
        sourceCount: sources.length,
        driveCount: derived.driveRows.length,
        localCount: derived.localRows.length,
        downloads: downloads,
      );
    }
    return [
      SliverToBoxAdapter(
        child: StreamsHeader(
          key: _streamsKey,
          state: state,
          sectioned: isSectioned,
          onSectionedChanged: _setStreamsSectioned,
          order: order,
          onOrderChanged: _setStreamsOrder,
        ),
      ),
      if (foundNothing)
        SliverToBoxAdapter(
          child: NoStreamsNotice(
            isEpisode: state.hasVideos,
            onAddons: _openAddons,
          ),
        ),
      if (noneYet)
        const SliverToBoxAdapter(
          child: ListTile(
            leading: Icon(Icons.touch_app_outlined),
            title: Text('Pick an episode to see its streams'),
          ),
        ),
      if (lastUsedStream != null)
        SliverToBoxAdapter(
          child: StreamTile(
            stream: lastUsedStream,
            highlighted: true,
            leadingIcon: Icons.history,
            titleOverride: kContinueWithLastSource,
            onTap: () => _play(state, lastUsed!.$1, lastUsedStream),
            downloads: downloads?.forGroup(lastUsed!.$1),
          ),
        ),
      if (isSectioned)
        for (final section in sections)
          ResolutionSectionSliver(
            section: section,
            expanded: openSections.contains(section.resolution),
            onExpand: () => _toggleSection(section.resolution),
            lastUsed: lastUsed?.$2,
            onPlay: (row) => _playRow(state, row),
            downloads: downloads,
          )
      else ...[
        for (final entry in grouped)
          StreamGroupSliver(
            group: entry,
            expanded: openAddons.contains(entry.storageLabel),
            onExpand: () => _toggleGroup(entry.storageLabel),
            lastUsed: lastUsed?.$2,
            onPlay: (row) => _playRow(state, row),
            downloads: downloadsFor(downloads, entry.group),
          ),
      ],
      const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
    ];
  }

  /// Puts the sources list in one layout or the other, for everything the
  /// app shows from now on: the preference is global, not this title's.
  ///
  /// The groups on a television are the layout's own, so the row that was
  /// open is about a grouping that no longer exists.
  void _setStreamsSectioned(bool value) {
    _openSourceGroup = null;
    _prefs?.setStreamsSectioned(value);
  }

  /// Puts every resolution section in one order or another, again for
  /// everything the app shows from now on rather than for this title.
  void _setStreamsOrder(StreamOrder value) => _prefs?.setStreamsOrder(value);

  /// Every resolution the viewer has ever opened, anywhere, parsed back
  /// from [AppPrefs.openStreamSections]. A label this build does not
  /// recognise -- a newer build's rung, a stray value -- is dropped rather
  /// than guessed at, the same as an unparseable [StreamOrder]. Empty both
  /// when nothing has ever been chosen and when the viewer collapsed
  /// everything on purpose; [AppPrefs.openStreamSections] is what keeps
  /// those two apart in storage; this screen draws them identically.
  Set<StreamResolution?> _rememberedOpenSections() {
    final result = <StreamResolution?>{};
    for (final label in _prefs?.openStreamSections ?? const <String>{}) {
      if (label == 'unknown') {
        result.add(null);
        continue;
      }
      for (final resolution in StreamResolution.values) {
        if (resolution.label == label) {
          result.add(resolution);
          break;
        }
      }
    }
    return result;
  }

  /// Which of [sections] are drawn open: the remembered resolutions this
  /// title actually offers, and nothing else. A remembered resolution the
  /// title does not have is simply not shown open -- never substituted
  /// with some other section the viewer did not ask for.
  Set<StreamResolution?> _visibleOpenSections(
    List<StreamSection<SourceRow>> sections,
  ) {
    final chosen = _rememberedOpenSections();
    return {
      for (final section in sections)
        if (chosen.contains(section.resolution)) section.resolution,
    };
  }

  /// Opens or closes one section, on the *full* remembered set (every
  /// resolution ever opened on any title), not just what this title shows
  /// open: otherwise closing a section here could silently drop a resolution
  /// another title still remembers, one this title never offered in the
  /// first place.
  void _toggleSection(StreamResolution? resolution) {
    final full = _rememberedOpenSections();
    final next = {
      for (final section in full)
        if (section != resolution) section,
      if (!full.contains(resolution)) resolution,
    };
    _prefs?.setOpenStreamSections({
      for (final section in next) _sectionStorageLabel(section),
    });
  }

  /// Every addon group the viewer has ever opened, anywhere, straight out
  /// of [AppPrefs.openStreamAddons]. Empty both when nothing has ever been
  /// chosen and when the viewer shut the last one on purpose -- both mean
  /// every group closed, which is what a fresh install shows.
  ///
  /// Each group asks this set for *its own* label, which is the rule
  /// [_visibleOpenSections] spells out for the resolutions: a remembered
  /// addon this title has no sources from opens nothing, and is never
  /// substituted with some other addon's group.
  Set<String> _rememberedOpenAddons() =>
      _prefs?.openStreamAddons ?? const <String>{};

  /// Opens or closes one addon group, on the *full* remembered set (every
  /// addon ever opened on any title), not just what this title shows open:
  /// otherwise closing a group here could silently drop an addon another
  /// title still remembers, one that had nothing for this title in the
  /// first place.
  void _toggleGroup(String label) {
    final full = _rememberedOpenAddons();
    _prefs?.setOpenStreamAddons({
      for (final addon in full)
        if (addon != label) addon,
      if (!full.contains(label)) label,
    });
  }
}
