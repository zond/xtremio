import 'package:flutter/material.dart';

import '../../core/core.dart';

/// `yyyy-MM-dd` of the air date, when the addon knows it.
///
/// Next to the still because both layouts put it under the same picture:
/// it is the second line of a row on a phone and of a card on a
/// television, and the two must not drift apart.
String? episodeDateLabel(VideoInfo video) {
  final date = video.releasedAt;
  if (date == null) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}

/// One episode's still, with the episode number over it.
///
/// The picture is the addon's `thumbnail`; a neutral box stands in when
/// there is none and when the one there is will not load, so a missing
/// image never disturbs the layout around it. The number is drawn on the
/// picture rather than beside it because it belongs to the still whatever
/// size the still is given -- a 96 dp leading image in the phone's episode
/// list, a whole card's width on a television.
///
/// The decode is bounded to the box the still is drawn in. A television
/// builds a whole season of these at once so that the D-pad can reach the
/// end of the row, and a season of stills decoded at whatever size the
/// addon serves them is real memory on the modest box this runs on.
class EpisodeThumbnail extends StatelessWidget {
  const EpisodeThumbnail({
    super.key,
    required this.video,
    this.width = listWidth,
    this.height = listHeight,
  });

  final VideoInfo video;

  /// The box the still is drawn in; the picture covers it.
  final double width;
  final double height;

  /// What the phone and desktop episode list leads each row with: 16:9,
  /// about as small as a still can be and still say anything.
  static const double listWidth = 96;
  static const double listHeight = 54;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnail = video.thumbnail;
    final episode = video.episode;
    // `cacheWidth` counts physical pixels, which is why the ratio is here.
    final pixels = (width * MediaQuery.devicePixelRatioOf(context)).round();
    return SizedBox(
      width: width,
      height: height,
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
                cacheWidth: pixels > 0 ? pixels : null,
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
