import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../widgets/poster_tile.dart';
import '../discover/discover_screen.dart';
import '../player/player_screen.dart';

/// One title: dispatches `Load MetaDetails` for [type]/[id] on mount and
/// shows the meta item, its episodes (for a series) and every stream the
/// installed addons return for the selected video.
///
/// The engine guesses the video to show streams for when it can (a movie,
/// or a `defaultVideoId`); for a series without one this screen picks the
/// first sensible episode itself and every episode tap re-`Load`s the field
/// with that video's stream path, so the streams list always follows the
/// selection. Tapping a playable stream opens the player.
class MetaDetailsScreen extends StatefulWidget {
  const MetaDetailsScreen({
    super.key,
    required this.type,
    required this.id,
    this.videoId,
  });

  final String type;
  final String id;

  /// The video to show streams for straight away (the continue-watching
  /// row knows it); without it the engine guesses, or the screen picks.
  final String? videoId;

  /// Above this width the streams sit in a side pane next to the details.
  static const double wideBreakpoint = 720;

  @override
  State<MetaDetailsScreen> createState() => _MetaDetailsScreenState();
}

class _MetaDetailsScreenState extends State<MetaDetailsScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _details;

  /// The screen whose `Load` the shared `meta_details` field last served.
  ///
  /// Two of these screens can be on the stack at once (a genre chip opens
  /// Discover, whose posters open another title), so the field is owned by
  /// whichever dispatched the last `Load`, and only the owner unloads it on
  /// dispose: a screen popping off above one that has already taken the
  /// field back (see [_reclaimField]) leaves it alone.
  static _MetaDetailsScreenState? _fieldOwner;

  /// The field's last state that was this screen's (its `metaPath` names
  /// [MetaDetailsScreen.id]) — what is rendered, also while another screen
  /// holds the field with a different title.
  MetaDetailsState? _ownState;
  Map<String, dynamic>? _ownJson;

  /// The video of the last `Load` this screen dispatched (null lets the
  /// engine guess), so the field can be reloaded with the same selection.
  String? _requestedVideoId;

  /// Whether this screen's route is on top; a covered screen ignores the
  /// field and reloads it when it is current again.
  bool _isCurrent = true;

  /// Set once the screen has picked an episode on the engine's behalf (or
  /// was told which video to open), so a later state without a stream path
  /// (unload, another title) does not trigger it again.
  late bool _pickedInitialVideo = widget.videoId != null;

  /// The season the episode list shows; null until the user (or the
  /// selected episode) chooses one.
  int? _season;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _details?.dispose();
      _client = client;
      _details = CoreFieldNotifier(client, CoreField.metaDetails)
        ..addListener(_onDetails);
      _load(widget.videoId);
    }
    // `ModalRoute.of` subscribes to the route's status, so this runs again
    // when another route is pushed over this one and when that route pops.
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (isCurrent && !_isCurrent) _reclaimField();
    _isCurrent = isCurrent;
  }

  @override
  void dispose() {
    if (_fieldOwner == this) {
      _fieldOwner = null;
      _client?.dispatch(CoreActions.unload(CoreField.metaDetails));
    }
    _details?.dispose();
    super.dispose();
  }

  MetaDetailsState? get _state => _ownState;

  /// Dispatches `Load MetaDetails` for this title, showing [videoId]'s
  /// streams (or letting the engine guess), and takes the field over.
  void _load(String? videoId) {
    _requestedVideoId = videoId;
    _fieldOwner = this;
    _client?.dispatch(
      CoreActions.loadMetaDetails(
        type: widget.type,
        id: widget.id,
        videoId: videoId,
      ),
    );
  }

  /// Back on top: if another screen loaded its title into the field in the
  /// meantime, load ours again with the selection it had. A route that left
  /// the field alone (the player) costs nothing here.
  void _reclaimField() {
    if (identical(_details?.value, _ownJson)) return;
    _load(_requestedVideoId ?? _ownState?.streamPath?.id);
  }

  void _onDetails() {
    final json = _details?.value;
    if (json == null) return;
    final state = MetaDetailsState.fromJson(json);
    // Another title (or the field unloaded) while a second details screen
    // holds the field: keep rendering our own last state.
    if (state.metaPath?.id != widget.id) return;
    _ownJson = json;
    _ownState = state;
    if (mounted) setState(() {});
    _maybePickInitialVideo(state);
  }

  /// Mirrors `selected_guess_stream_update`: when the engine will not pick a
  /// stream path for this title (a series without a default video), select
  /// the initial episode once the meta is in so streams load without a tap.
  void _maybePickInitialVideo(MetaDetailsState state) {
    if (_pickedInitialVideo) return;
    if (state.streamPath != null || state.engineWillGuessStream) return;
    final video = state.initialVideo(preferred: widget.videoId);
    if (video == null) return;
    _pickedInitialVideo = true;
    _selectVideo(video);
  }

  void _selectVideo(VideoInfo video) {
    if (mounted) setState(() => _season = video.season);
    _load(video.id);
  }

  void _toggleWatched(MetaDetailsState state, VideoInfo video) {
    _client?.dispatch(
      CoreActions.markVideoAsWatched(
        video.json,
        watched: !state.isWatched(video),
      ),
    );
  }

  void _play(MetaDetailsState state, StreamGroup group, StreamInfo stream) {
    final videoId = state.streamPath?.id ?? state.meta?.id ?? widget.id;
    Navigator.of(context)
        .push(
          MaterialPageRoute<PlayerScreenResult>(
            settings: const RouteSettings(name: 'player'),
            builder: (_) => PlayerScreen(
              stream: stream.json,
              streamRequest: group.request,
              metaRequest: state.metaRequest,
              subtitlesPath: ResourcePath(
                resource: 'subtitles',
                type: widget.type,
                id: videoId,
              ),
            ),
          ),
        )
        .then((result) {
          // The player wanted the next episode but had no stream for it:
          // show that episode's streams.
          if (result != null && mounted) _selectVideoId(result.selectVideoId);
        });
  }

  void _selectVideoId(String videoId) {
    final video = _ownState?.meta?.videoById(videoId);
    if (video != null) {
      _selectVideo(video);
    } else {
      _load(videoId);
    }
  }

  void _openGenre(ResourceRequest request) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'discover'),
        builder: (_) => DiscoverScreen(request: request),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final meta = state?.meta;
    if (state == null || meta == null) {
      final error = state?.metaError;
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: error == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Could not load this title: ${error.message}',
                    textAlign: TextAlign.center,
                  ),
                ),
        ),
      );
    }
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide =
              constraints.maxWidth >= MetaDetailsScreen.wideBreakpoint;
          final info = _infoSlivers(state, meta, isWide: isWide);
          final streams = _streamSlivers(state, meta);
          if (!isWide) {
            return CustomScrollView(slivers: [...info, ...streams]);
          }
          final paneWidth = (constraints.maxWidth * 0.38).clamp(320.0, 480.0);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: CustomScrollView(slivers: info)),
              const VerticalDivider(width: 1),
              SizedBox(
                width: paneWidth,
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.only(
                        top: MediaQuery.paddingOf(context).top + 8,
                      ),
                    ),
                    ...streams,
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Hero, facts and (for a series) the season selector and episode list.
  List<Widget> _infoSlivers(
    MetaDetailsState state,
    MetaItem meta, {
    required bool isWide,
  }) {
    final seasons = meta.seasons;
    final season =
        _season ??
        state.selectedVideo?.season ??
        state.initialVideo(preferred: widget.videoId)?.season ??
        (seasons.isEmpty ? null : seasons.first);
    final episodes = season == null ? meta.videos : meta.videosOfSeason(season);
    final now = DateTime.now().toUtc();
    return [
      SliverAppBar(
        pinned: true,
        expandedHeight: isWide ? 300 : 220,
        flexibleSpace: FlexibleSpaceBar(
          title: Text(meta.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          background: _Backdrop(url: meta.background, logo: meta.logo),
        ),
      ),
      SliverToBoxAdapter(
        child: _MetaHeader(meta: meta, isWide: isWide, onGenre: _openGenre),
      ),
      if (state.hasVideos) ...[
        if (seasons.length > 1 && season != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: _SeasonSelector(
                seasons: seasons,
                selected: season,
                isWide: isWide,
                onChanged: (season) => setState(() => _season = season),
              ),
            ),
          ),
        SliverList.builder(
          itemCount: episodes.length,
          itemBuilder: (context, index) {
            final video = episodes[index];
            return _EpisodeTile(
              video: video,
              isSelected: video.id == state.streamPath?.id,
              isWatched: state.isWatched(video),
              isReleased: video.isReleased(now),
              onTap: () => _selectVideo(video),
              onLongPress: () => _toggleWatched(state, video),
            );
          },
        ),
      ],
      const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
    ];
  }

  /// The streams for the selected video, the meta addon's own first. The
  /// engine lists every addon it asked from the moment of the request (as
  /// `Loading` groups), so the header's small spinner is the only loading
  /// indicator needed; an empty list means no addon was asked.
  List<Widget> _streamSlivers(MetaDetailsState state, MetaItem meta) {
    final lastUsed = state.lastUsedStream;
    final groups = state.allStreamGroups;
    final noneYet =
        state.hasVideos && state.streamPath == null && groups.isEmpty;
    return [
      SliverToBoxAdapter(child: _StreamsHeader(state: state)),
      if (noneYet)
        const SliverToBoxAdapter(
          child: ListTile(
            leading: Icon(Icons.touch_app_outlined),
            title: Text('Pick an episode to see its streams'),
          ),
        ),
      if (lastUsed != null)
        SliverToBoxAdapter(
          child: _StreamTile(
            stream: lastUsed.$2,
            highlighted: true,
            leadingIcon: Icons.history,
            titleOverride: 'Continue with last source',
            onTap: () => _play(state, lastUsed.$1, lastUsed.$2),
          ),
        ),
      for (final group in groups)
        _StreamGroupSliver(
          group: group,
          lastUsed: lastUsed?.$2,
          onPlay: (stream) => _play(state, group, stream),
        ),
      const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
    ];
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.url, required this.logo});

  final String? url;
  final String? logo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = this.url;
    final logo = this.logo;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: scheme.surfaceContainerHighest),
        if (url != null)
          Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black26,
                Colors.black38,
                scheme.surface.withValues(alpha: 0.85),
              ],
            ),
          ),
        ),
        if (logo != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 64,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Image.network(
                logo,
                height: 56,
                fit: BoxFit.contain,
                alignment: Alignment.bottomLeft,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
      ],
    );
  }
}

class _MetaHeader extends StatelessWidget {
  const _MetaHeader({
    required this.meta,
    required this.isWide,
    required this.onGenre,
  });

  final MetaItem meta;
  final bool isWide;
  final ValueChanged<ResourceRequest> onGenre;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final facts = [?meta.releaseInfo, ?meta.runtime, meta.type].join(' · ');
    final rating = meta.imdbRating;
    final genres = meta.genres;
    final posterWidth = isWide ? 130.0 : 90.0;
    final description = meta.description;

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(facts, style: theme.textTheme.labelLarge),
        if (rating != null) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.star_rounded, size: 18, color: Colors.amber.shade400),
              const SizedBox(width: 4),
              Text(rating, style: theme.textTheme.labelLarge),
              const SizedBox(width: 4),
              Text(
                'IMDb',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
        if (genres.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: -8,
            children: [
              for (final genre in genres)
                ActionChip(
                  label: Text(genre.name),
                  visualDensity: VisualDensity.compact,
                  onPressed: switch (genre.discoverRequest) {
                    null => null,
                    final request => () => onGenre(request),
                  },
                ),
            ],
          ),
        ],
        if (isWide && description != null) ...[
          const SizedBox(height: 12),
          _ExpandableText(description),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: posterWidth,
                height: posterWidth * 1.5,
                child: PosterImage(url: meta.poster),
              ),
              const SizedBox(width: 16),
              Expanded(child: details),
            ],
          ),
          if (!isWide && description != null) ...[
            const SizedBox(height: 12),
            _ExpandableText(description),
          ],
        ],
      ),
    );
  }
}

/// Body text clamped to a few lines with a "More" toggle when it overflows.
class _ExpandableText extends StatefulWidget {
  const _ExpandableText(this.text);

  final String text;

  static const int collapsedLines = 4;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium;
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: _ExpandableText.collapsedLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: _expanded ? null : _ExpandableText.collapsedLines,
              overflow: _expanded ? null : TextOverflow.ellipsis,
            ),
            if (overflows)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? 'Less' : 'More'),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Season picker: a segmented button where there is room, a dropdown on
/// phones or for very long series. Season 0 is labelled "Specials".
class _SeasonSelector extends StatelessWidget {
  const _SeasonSelector({
    required this.seasons,
    required this.selected,
    required this.isWide,
    required this.onChanged,
  });

  final List<int> seasons;
  final int selected;
  final bool isWide;
  final ValueChanged<int> onChanged;

  static String label(int season) =>
      season == 0 ? 'Specials' : 'Season $season';

  @override
  Widget build(BuildContext context) {
    if (isWide && seasons.length <= 8) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [
            for (final season in seasons)
              ButtonSegment(value: season, label: Text(label(season))),
          ],
          selected: {selected},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
      );
    }
    return DropdownMenu<int>(
      key: ValueKey(selected),
      initialSelection: selected,
      requestFocusOnTap: false,
      dropdownMenuEntries: [
        for (final season in seasons)
          DropdownMenuEntry(value: season, label: label(season)),
      ],
      onSelected: (season) {
        if (season != null) onChanged(season);
      },
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.video,
    required this.isSelected,
    required this.isWatched,
    required this.isReleased,
    required this.onTap,
    required this.onLongPress,
  });

  final VideoInfo video;
  final bool isSelected;
  final bool isWatched;
  final bool isReleased;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// `yyyy-MM-dd` of the air date, when known.
  static String? dateLabel(VideoInfo video) {
    final date = video.releasedAt;
    if (date == null) return null;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = dateLabel(video);
    final episode = video.episode;
    final title = video.title.isEmpty && episode != null
        ? 'Episode $episode'
        : video.title;
    return ListTile(
      selected: isSelected,
      enabled: isReleased,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: _EpisodeThumbnail(video: video),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: date == null && isReleased
          ? null
          : Text(
              [?date, if (!isReleased) 'Upcoming'].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
      trailing: isWatched
          ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
          : isSelected
          ? const Icon(Icons.play_arrow)
          : null,
    );
  }
}

class _EpisodeThumbnail extends StatelessWidget {
  const _EpisodeThumbnail({required this.video});

  final VideoInfo video;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnail = video.thumbnail;
    final episode = video.episode;
    return SizedBox(
      width: 96,
      height: 54,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
            if (thumbnail != null)
              Image.network(
                thumbnail,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            if (episode != null)
              Positioned(
                left: 4,
                bottom: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    child: Text(
                      'E$episode',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StreamsHeader extends StatelessWidget {
  const _StreamsHeader({required this.state});

  final MetaDetailsState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final video = state.selectedVideo;
    final meta = state.meta;
    final subtitle = video != null && meta != null && video.id != meta.id
        ? [
            if (video.seasonEpisodeLabel.isNotEmpty) video.seasonEpisodeLabel,
            if (video.title.isNotEmpty) video.title,
          ].join(' · ')
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
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
          if (state.isLoadingStreams)
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

class _StreamGroupSliver extends StatelessWidget {
  const _StreamGroupSliver({
    required this.group,
    required this.lastUsed,
    required this.onPlay,
  });

  final StreamGroup group;

  /// The stream pinned as "Continue with last source", highlighted here too.
  final StreamInfo? lastUsed;
  final ValueChanged<StreamInfo> onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = group.error;
    final streams = group.streams;
    final label = group.isFromMeta
        ? 'From ${group.addonLabel}'
        : group.addonLabel;
    final settledEmpty =
        streams.isEmpty &&
        (error?.isEmptyContent == true ||
            (error == null && group.content != null));
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (error != null && !error.isEmptyContent)
          SliverToBoxAdapter(
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.cloud_off_outlined),
              title: Text(error.message),
            ),
          )
        else if (settledEmpty)
          const SliverToBoxAdapter(
            child: ListTile(dense: true, title: Text('No streams')),
          ),
        SliverList.builder(
          itemCount: streams.length,
          itemBuilder: (context, index) {
            final stream = streams[index];
            final lastUsed = this.lastUsed;
            return _StreamTile(
              stream: stream,
              highlighted: lastUsed != null && stream.isSameSource(lastUsed),
              onTap: stream.isPlayable ? () => onPlay(stream) : null,
            );
          },
        ),
      ],
    );
  }
}

/// One stream: its name, what is left of the description once the quality
/// hints are pulled out into chips, and a play affordance (or the kind of
/// source when the player cannot open it).
class _StreamTile extends StatelessWidget {
  const _StreamTile({
    required this.stream,
    required this.onTap,
    this.highlighted = false,
    this.leadingIcon,
    this.titleOverride,
  });

  final StreamInfo stream;
  final VoidCallback? onTap;
  final bool highlighted;
  final IconData? leadingIcon;
  final String? titleOverride;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hints = StreamHints.of(stream);
    final title = titleOverride ?? stream.title;
    // A name that is nothing but the hint ("1080p") needs no chip for it.
    final chips = [
      for (final chip in hints.chips)
        if (chip.toLowerCase() != stream.title.toLowerCase()) chip,
    ];
    final description = titleOverride != null
        ? stream.title
        : stream.name == null
        ? null
        : hints.strip(stream.description);
    final tile = ListTile(
      enabled: onTap != null,
      selected: highlighted,
      leading: Icon(leadingIcon ?? _iconFor(stream.kind)),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: description != null && chips.isNotEmpty,
      subtitle: description == null && chips.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (description != null)
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
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
      trailing: onTap != null
          ? const Icon(Icons.play_arrow)
          : Text(stream.kind.label, style: theme.textTheme.labelSmall),
      onTap: onTap,
    );
    final filename = hints.filename;
    return filename == null ? tile : Tooltip(message: filename, child: tile);
  }

  static IconData _iconFor(StreamKind kind) => switch (kind) {
    StreamKind.torrent || StreamKind.magnet => Icons.cloud_download_outlined,
    StreamKind.url => Icons.link,
    StreamKind.youtube => Icons.smart_display_outlined,
    StreamKind.external => Icons.open_in_new,
    StreamKind.playerFrame => Icons.web,
    StreamKind.archive => Icons.folder_zip_outlined,
    StreamKind.unknown => Icons.help_outline,
  };
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
