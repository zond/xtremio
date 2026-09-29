part of 'meta_details_screen.dart';

// These are the State's own methods, split out by concern; an extension
// is not a subclass, so the analyzer flags their `setState` calls.
// ignore_for_file: invalid_use_of_protected_member

/// What a shut episodes rung says it holds: which season is under it and
/// how many episodes that is.
String _episodesSummary(int? season, int count) => season == null
    ? (count == 1 ? '1 episode' : '$count episodes')
    : 'Season $season · $count';

/// The title's own slivers: the app bar, the header, and a series' seasons
/// and episodes.
extension _MetaDetailsInfo on _MetaDetailsScreenState {
  /// Hero, facts and (for a series) the season selector and episode list.
  ///
  /// On a television the hero is gone: [TvBackdrop] is already drawing the
  /// artwork across the whole panel, so a second copy of it inside a
  /// collapsing app bar would be the same picture twice. What is left of
  /// the bar is the way back and the way to the downloads list, floating
  /// over the backdrop.
  ///
  /// The episodes are a [TvEpisodeRow] there and a [SliverList] of
  /// [EpisodeTile]s everywhere else. The two carry the same things about
  /// an episode and are otherwise unrelated shapes, which is why this is a
  /// branch rather than one list laid out two ways.
  List<Widget> _infoSlivers(
    MetaDetailsState state,
    MetaItem meta, {
    required bool isWide,
    required bool isTv,
  }) {
    final seasons = meta.seasons;
    final season =
        _season ??
        _resumedSeason(state, seasons) ??
        state.selectedVideo?.season ??
        state.initialVideo(preferred: _preferredVideoId(state))?.season ??
        (seasons.isEmpty ? null : seasons.first);
    final episodes = season == null ? meta.videos : meta.videosOfSeason(season);
    _shownVideoId = _selectedVideoId(state);
    final now = DateTime.now().toUtc();
    // The trailer opens in the YouTube app, never the player: see
    // [TrailerButton].
    final trailer = meta.trailerUrl;
    final onTrailer = trailer == null
        ? null
        : () => openInBrowser(context, trailer.toString());
    return [
      SliverAppBar(
        pinned: !isTv,
        expandedHeight: isTv ? null : (isWide ? 300 : 220),
        backgroundColor: isTv ? Colors.transparent : null,
        scrolledUnderElevation: isTv ? 0 : null,
        // The way out, and it leaves rather than going through
        // `Navigator.maybePop` the way the bar's own [BackButton] does:
        // on a television that press is answered by the ladder below,
        // which puts the open row of sources away and leaves the viewer
        // on the screen they aimed to leave. Back is the key that comes
        // down a ladder, because it is one key for every layer; this is a
        // control the viewer pointed at. Drawn only where there is
        // something to go back to, as the implied one is, so it is never
        // an arrow that does nothing.
        leading: Navigator.of(context).canPop()
            ? _AboveTheLadder(
                isTv: isTv,
                child: BackButton(onPressed: () => Navigator.of(context).pop()),
              )
            : null,
        actions: [
          if (_downloadsClient != null)
            _AboveTheLadder(
              isTv: isTv,
              child: IconButton(
                tooltip: kDownloadsScreenTooltip,
                onPressed: _openDownloads,
                icon: const Icon(Icons.download_outlined),
              ),
            ),
        ],
        flexibleSpace: isTv
            ? null
            : FlexibleSpaceBar(
                title: Text(
                  meta.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                background: DetailsBackdrop(
                  url: meta.background,
                  logo: meta.logo,
                ),
              ),
      ),
      SliverToBoxAdapter(
        child: isTv
            ? TvLadderRow(
                level: _ladderInfo,
                child: TvMetaHeader(
                  meta: meta,
                  isInLibrary: state.isInLibrary,
                  downloads: _downloads?.ofMeta(widget.id) ?? const [],
                  onToggleLibrary: () => _toggleLibrary(state, meta),
                  onTrailer: onTrailer,
                ),
              )
            : DetailsMetaHeader(
                meta: meta,
                isWide: isWide,
                isInLibrary: state.isInLibrary,
                downloads: _downloads?.ofMeta(widget.id) ?? const [],
                onGenre: _openGenre,
                onToggleLibrary: () => _toggleLibrary(state, meta),
                onTrailer: onTrailer,
              ),
      ),
      if (state.hasVideos) ...[
        if (isTv)
          // The season and its episodes are one rung: picking a season is
          // picking which episodes are under it, and a viewer looking for
          // an episode wants both or neither. Its header says which season
          // and how many, which is the whole of what a shut rung owes.
          SliverToBoxAdapter(
            child: TvLadderRung(
              level: _ladderEpisodesHeader,
              label: kEpisodesLabel,
              summary: _episodesSummary(season, episodes.length),
              open: _shownRung == _DetailsRung.episodes,
              onSelect: () => _selectRung(_DetailsRung.episodes),
              children: [
                if (seasons.length > 1 && season != null)
                  TvLadderRow(
                    level: _ladderSeasons,
                    advanceOnSelect: true,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: SeasonSelector(
                        seasons: seasons,
                        selected: season,
                        onChanged: _chooseSeason,
                      ),
                    ),
                  ),
                TvLadderRow(
                  level: _ladderEpisodes,
                  advanceOnSelect: true,
                  child: TvEpisodeRow(
                    episodes: episodes,
                    selectedVideoId: _selectedVideoId(state),
                    homeVideoId: _requestedVideoId,
                    now: now,
                    // The remote starts here only when this is the rung
                    // the title is for and nothing has taken it yet: a
                    // rung the viewer opens themselves leaves them on the
                    // header they pressed, one press above the row.
                    defaultFocus:
                        _shownRung == _DetailsRung.episodes &&
                        _startedOn == null,
                    isWatched: state.isWatched,
                    resumeProgress: (video) => _resumeProgress(state, video),
                    downloadOf: (video) =>
                        _downloads?.forVideo(widget.id, video.id),
                    onSelect: (video) => _selectVideo(video, reveal: true),
                    onToggleWatched: (video) => _toggleWatched(state, video),
                    onFocus: _focusVideo,
                  ),
                ),
              ],
            ),
          )
        else ...[
          if (seasons.length > 1 && season != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: SeasonSelector(
                  seasons: seasons,
                  selected: season,
                  onChanged: _chooseSeason,
                ),
              ),
            ),
          SliverList.builder(
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final video = episodes[index];
              return EpisodeTile(
                video: video,
                isSelected: video.id == _selectedVideoId(state),
                isWatched: state.isWatched(video),
                isReleased: video.isReleased(now),
                download: _downloads?.forVideo(widget.id, video.id),
                onDeleteDownload: _deleteDownload,
                onTap: () => _selectVideo(video, reveal: true),
                onLongPress: () => _toggleWatched(state, video),
              );
            },
          ),
        ],
      ],
      // The same films a television gets, as an ordinary section rather
      // than a rung: this column is what the title *is* -- its name, its
      // description, its episodes -- and what it is like belongs at the
      // end of it. Below the breakpoint that puts it between the episodes
      // and the sources, and on a wide layout at the foot of the left
      // pane, which is the same place in both. It is drawn only where
      // there is no ladder: the television has one.
      if (!isTv && _hasSimilar)
        SliverToBoxAdapter(
          child: SimilarSection(titles: _similar, onOpen: _openSimilar),
        ),
      const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
    ];
  }
}
