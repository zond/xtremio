import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/tv_density.dart';
import '../../widgets/download_badge.dart';
import '../../widgets/focusable_tile.dart';
import 'episode_thumbnail.dart';

/// A season's episodes as one row of cards, scrolled sideways: what the
/// phone and desktop layouts show as a vertical list of rows.
///
/// A remote walks a row with two keys and a list with a hundred, and a
/// television has width to spare and no height at all once the backdrop,
/// the header and the sources are on the panel. So an episode becomes a
/// card carrying exactly what its row carried -- the still with its number
/// on it, the title, the air date, whether it has been watched, whatever
/// of it is on the device -- plus the one thing the list had nowhere to
/// put: how far into this episode the viewer got.
///
/// Two things about it are not cosmetic:
///
/// - **Every card is built, always.** Directional focus only considers
///   widgets that have been built, so a lazily built row hands the D-pad
///   back at the last realised card and the rest of the season is
///   unreachable. This is a [SingleChildScrollView] over a [Row] -- the
///   same shape the season pills above it use -- and not a
///   `ListView.builder`. What that costs is bounded instead by decoding
///   each still no larger than the card it is drawn in
///   ([EpisodeThumbnail]), because a season of full-size stills on the
///   Chromecast this is used on is real memory.
/// - **The row opens where the viewer left off.** The selected episode is
///   scrolled to the middle when the row is built and whenever the
///   selection moves, so resuming a series at episode 19 does not start
///   the remote at episode 1.
///
/// An episode that has not aired is drawn but takes no press and no focus,
/// exactly as its list row is disabled today; the remote steps over it.
class TvEpisodeRow extends StatefulWidget {
  const TvEpisodeRow({
    super.key,
    required this.episodes,
    required this.selectedVideoId,
    required this.now,
    required this.isWatched,
    required this.resumeProgress,
    required this.downloadOf,
    required this.onSelect,
    required this.onToggleWatched,
  });

  /// The episodes of the season on screen, in order.
  final List<VideoInfo> episodes;

  /// The episode whose sources are shown; null before anything is picked.
  final String? selectedVideoId;

  /// What "has aired" is measured against.
  final DateTime now;

  final bool Function(VideoInfo video) isWatched;

  /// How far into [video] the library says the viewer got, `0..1`, or null
  /// when it says nothing about this episode. The engine remembers one
  /// resume point per title, so at most one card in the row has a bar.
  final double? Function(VideoInfo video) resumeProgress;

  /// This episode's download, whatever source it was taken from.
  final DownloadView? Function(VideoInfo video) downloadOf;

  /// Show this episode's sources (a tap, or the remote's select).
  final ValueChanged<VideoInfo> onSelect;

  /// Toggle watched (a long press, the remote's menu key, a held select).
  final ValueChanged<VideoInfo> onToggleWatched;

  /// How wide one card is. Three of them and the edge of a fourth fit the
  /// info column of a 720p panel, which is what says the row scrolls.
  static const double cardWidth = 208;

  /// The gap between two cards.
  static const double gap = 12;

  /// The margin at either end of the row.
  static const double sidePadding = 16;

  /// Room kept above and below the cards for a focused one to grow into.
  ///
  /// A strip clips to exactly its own bounds, so without this the zoom and
  /// the shadow a focused card wears are cut off at both edges and read as
  /// a crop. The Board's rows spend the same 12 dp on it.
  static const double focusSlack = 12;

  /// The still: the card's own width, at 16:9.
  static const double thumbnailHeight = cardWidth * 9 / 16;

  /// Between the still and the words under it.
  static const double captionGap = 6;

  /// The box the title and the date are drawn in, at text scale 1: two
  /// lines of title over one of date.
  static const double captionHeight = 64;

  /// How long the scroll that brings the selected card into view takes.
  static const Duration revealDuration = Duration(milliseconds: 200);

  /// What the row measures, including the room a focused card grows into.
  ///
  /// The caption is the only part that grows with the text scale: the
  /// still keeps its size, so the row grows by exactly what the words
  /// gained rather than squeezing the picture ([TvDensity.textFactorOf],
  /// never below 1 -- the box is an exact fit at 1 and the padding in it
  /// is fixed, so a smaller system font would overflow it rather than
  /// shrink it).
  static double heightOf(BuildContext context) =>
      focusSlack * 2 +
      thumbnailHeight +
      captionGap +
      captionHeight * math.max(1, TvDensity.textFactorOf(context));

  @override
  State<TvEpisodeRow> createState() => _TvEpisodeRowState();
}

class _TvEpisodeRowState extends State<TvEpisodeRow> {
  final ScrollController _controller = ScrollController();

  /// One key per episode, so the reveal below can find the card's box.
  final Map<String, GlobalKey> _cards = {};

  List<String> get _ids => [for (final v in widget.episodes) v.id];

  @override
  void initState() {
    super.initState();
    _revealSelected();
  }

  @override
  void didUpdateWidget(TvEpisodeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final moved = oldWidget.selectedVideoId != widget.selectedVideoId;
    final replaced = !listEquals([
      for (final v in oldWidget.episodes) v.id,
    ], _ids);
    if (moved || replaced) _revealSelected();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Centres the selected card, once the frame that laid it out is on
  /// screen: a card built this frame has no box yet.
  void _revealSelected() {
    final id = widget.selectedVideoId;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final box = _cards[id]?.currentContext?.findRenderObject();
      if (box == null) return;
      _controller.position.ensureVisible(
        box,
        alignment: 0.5,
        duration: TvEpisodeRow.revealDuration,
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ids = _ids.toSet();
    _cards.removeWhere((id, _) => !ids.contains(id));
    return SizedBox(
      height: TvEpisodeRow.heightOf(context),
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: TvEpisodeRow.sidePadding,
          vertical: TvEpisodeRow.focusSlack,
        ),
        child: Row(
          spacing: TvEpisodeRow.gap,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final video in widget.episodes)
              SizedBox(
                key: _cards.putIfAbsent(video.id, GlobalKey.new),
                width: TvEpisodeRow.cardWidth,
                child: TvEpisodeCard(
                  video: video,
                  isSelected: video.id == widget.selectedVideoId,
                  isWatched: widget.isWatched(video),
                  isReleased: video.isReleased(widget.now),
                  progress: widget.resumeProgress(video),
                  download: widget.downloadOf(video),
                  onTap: () => widget.onSelect(video),
                  onLongPress: () => widget.onToggleWatched(video),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One episode of [TvEpisodeRow]: the still with everything known about
/// this episode drawn on it, the title and the air date below.
///
/// Everything that is a *state* of the episode goes on the picture rather
/// than beside the words, because that is the part of a card the eye lands
/// on from across a room: the number it already carried, the check when it
/// has been watched, the badge when it is kept on the device, and the bar
/// saying how far in the viewer got. The words say which episode it is.
class TvEpisodeCard extends StatelessWidget {
  const TvEpisodeCard({
    super.key,
    required this.video,
    required this.isSelected,
    required this.isWatched,
    required this.isReleased,
    required this.onTap,
    required this.onLongPress,
    this.progress,
    this.download,
  });

  final VideoInfo video;

  /// Its sources are the ones on screen.
  final bool isSelected;

  final bool isWatched;

  /// It has aired. An episode that has not takes no press at all, so it is
  /// not a focus stop either and the remote steps over it.
  final bool isReleased;

  /// `0..1` into this episode, or null when nothing is remembered of it.
  final double? progress;

  final DownloadView? download;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// How tall the resume bar across the foot of the still is.
  static const double resumeBarHeight = 4;

  /// Rounds the still, the card's ink and its focus ring.
  static const BorderRadius radius = BorderRadius.all(Radius.circular(8));

  /// What the second line reads: the air date, and "Upcoming" for an
  /// episode that has not aired -- the same line the phone's list row
  /// carries, and the only thing saying why a card takes no press.
  static String subtitle(VideoInfo video, {required bool isReleased}) =>
      [?episodeDateLabel(video), if (!isReleased) 'Upcoming'].join(' · ');

  /// The title, or `Episode N` when the addon sent none.
  static String title(VideoInfo video) {
    final episode = video.episode;
    if (video.title.isEmpty && episode != null) return 'Episode $episode';
    return video.title;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = subtitle(video, isReleased: isReleased);
    return FocusableTile(
      onTap: isReleased ? onTap : null,
      onLongPress: isReleased ? onLongPress : null,
      memoryId: 'details/episode/${video.id}',
      borderRadius: radius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _still(theme),
          const SizedBox(height: TvEpisodeRow.captionGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: Text(
                    title(video),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isSelected ? theme.colorScheme.primary : null,
                      // Never colour alone: a tint is the first cue a
                      // bright room takes away, and which episode is
                      // showing is the one thing this row has to say.
                      fontWeight: isSelected ? FontWeight.w700 : null,
                    ),
                  ),
                ),
                if (line.isNotEmpty)
                  Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The still, with the states drawn over it.
  Widget _still(ThemeData theme) {
    final download = this.download;
    final progress = this.progress;
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        height: TvEpisodeRow.thumbnailHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            EpisodeThumbnail(
              video: video,
              width: TvEpisodeRow.cardWidth,
              height: TvEpisodeRow.thumbnailHeight,
            ),
            if (download != null)
              Positioned(
                top: 4,
                left: 4,
                child: _OverStill(child: DownloadBadge(download: download)),
              ),
            if (isWatched)
              Positioned(
                top: 4,
                right: 4,
                child: _OverStill(
                  child: Icon(
                    Icons.check_circle,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            if (progress != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: resumeBarHeight,
                  backgroundColor: Colors.black.withValues(alpha: 0.55),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A mark drawn on a still: whatever frame is underneath, it is read
/// against this rather than against the picture.
class _OverStill extends StatelessWidget {
  const _OverStill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.65),
      shape: BoxShape.circle,
    ),
    child: Padding(padding: const EdgeInsets.all(3), child: child),
  );
}
