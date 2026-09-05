import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import 'playback_stats.dart';
import 'torrent_progress_card.dart';
import 'torrent_stats.dart';

/// The stats OSD: a small translucent monospace panel listing what the
/// engine reports in [PlaybackStats], and for a torrent what the embedded
/// server reports about the swarm feeding it ([torrent]).
///
/// Subscribes to [stats] for as long as it is mounted, so whoever shows it
/// controls when the engine samples: mount it to start, unmount to stop.
/// The torrent rows are polled by the player, which keeps them coming for
/// as long as this panel is up.
class PlaybackStatsOverlay extends StatelessWidget {
  const PlaybackStatsOverlay({
    super.key,
    required this.stats,
    this.source,
    this.isTorrent = false,
    this.torrent,
    this.dht,
  });

  final Stream<PlaybackStats> stats;

  /// The URL libmpv is playing, shown as the last line (a torrent reads
  /// `http://127.0.0.1:11470/<infoHash>/<fileIdx>?tr=…`).
  final Uri? source;

  /// The stream is a torrent the embedded server is serving: the swarm
  /// rows belong in the panel, even before [torrent] has arrived. False for
  /// a direct HTTP stream, which has no swarm to describe.
  final bool isTorrent;

  /// The latest `stats.json` for that torrent, or null while the player's
  /// poll has not answered yet.
  final TorrentStats? torrent;

  /// The DHT's status, read once when this torrent's polling started; null
  /// when it was not asked or could not be read. Shown as its own row only
  /// when [DhtStatus.unavailable] -- a bootstrapped or disabled DHT is not
  /// news, and this panel is not where it would be worth a row anyway.
  final DhtStatus? dht;

  static const TextStyle _style = TextStyle(
    color: Colors.white,
    fontFamily: 'monospace',
    fontFamilyFallback: ['Menlo', 'Consolas', 'DejaVu Sans Mono'],
    fontSize: 11,
    height: 1.35,
  );

  /// The font size the panel uses on a television. The set's global text
  /// scale alone leaves the 11pt monospace of a desktop unreadable from a
  /// sofa, and this panel is the one place where the numbers are the whole
  /// point of looking.
  static const double tvFontSize = 16;

  /// How wide the two rows carrying text from somewhere else -- the
  /// server's reason for stopping, and the URL -- are allowed to get.
  /// Every other row is short by construction; these two are as long as
  /// whoever wrote them, and unbounded either one stretches the panel
  /// across the picture.
  static const double wideRowWidth = 480;

  /// One of those rows: held to [wideRowWidth] and cut off with an
  /// ellipsis rather than wrapping down the frame.
  static Widget _wideRow(
    String text,
    TextStyle style, {
    required int maxLines,
  }) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: wideRowWidth),
    child: Text(
      text,
      style: style,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final style = DeviceScope.isTv(context)
        ? _style.copyWith(fontSize: tvFontSize)
        : _style;
    return StreamBuilder<PlaybackStats>(
      stream: stats,
      builder: (context, snapshot) {
        final sample = snapshot.data;
        return IgnorePointer(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line
                    in sample == null
                        ? const ['stats: collecting…']
                        : describe(sample))
                  Text(line, style: style),
                if (isTorrent) ...[
                  for (final line in describeTorrent(torrent))
                    Text(line, style: style),
                  if (describeTorrentError(torrent) case final error?)
                    _wideRow(error, style, maxLines: 2),
                  if (dht?.unavailable ?? false)
                    Text(describeDht(dht!), style: style),
                ],
                if (source != null)
                  _wideRow('url      $source', style, maxLines: 1),
              ],
            ),
          ),
        );
      },
    );
  }

  /// One text line per stat, in the order the panel shows them.
  static List<String> describe(PlaybackStats s) => [
    'fps      ${_fps(s.outputFps)} out / ${_fps(s.containerFps)} container',
    'dropped  ${s.droppedFrames ?? '-'} vo'
        '${s.decoderDroppedFrames == null ? '' : ' / ${s.decoderDroppedFrames} decoder'}',
    'hwdec    ${_hwdec(s)}',
    'video    ${s.videoCodec ?? '-'}'
        '${s.width != null && s.height != null ? ' ${s.width}x${s.height}' : ''}',
    'bitrate  ${formatBitrate(s.videoBitrate)}',
    'cache    ${_cache(s)}',
    // Only when mpv answered: on a backend that has no such properties
    // the rows would be three dashes claiming something was measured.
    if (s.seekable != null || s.partiallySeekable != null)
      'seekable ${_seekable(s)} · partially ${_flag(s.partiallySeekable)}',
    if (s.seekableRanges case final ranges?) 'ranges   ${_ranges(ranges)}',
  ];

  /// A yes/no mpv answered, or a dash for one it did not.
  static String _flag(bool? value) => switch (value) {
    null => '-',
    true => 'yes',
    false => 'no',
  };

  /// Whether mpv will seek in the open media -- and whose answer that is.
  ///
  /// `forced` rather than `yes` when we set `force-seekable` for this
  /// stream, which the player does for the embedded server's own URLs: the
  /// row is then our claim rather than a reading, and reporting it as a
  /// reading is what would send someone looking in the wrong place. What
  /// still reads is `partially`, which mpv sets alongside a forced
  /// `seekable`: a yes there under `forced` is the demuxer saying it could
  /// not seek and being overruled.
  static String _seekable(PlaybackStats s) =>
      s.seekableForced == true ? 'forced' : _flag(s.seekable);

  /// The demuxer's seekable ranges, in whole seconds of playback time.
  ///
  /// `none` is a reading and not a blank -- but it is not on its own a
  /// fault, and it must not be read as one. mpv refuses a seek on
  /// `seekable`; the ranges say only what the cache can serve without
  /// going back to the demuxer, and nothing is recorded until a whole
  /// keyframe range has been queued, so `none` is what every file reads
  /// for its first seconds while every seek works. What the row is for is
  /// the pair: which parts a seek lands in without a wait, next to the
  /// `seekable`/`partially` row that says whether one can be made at all.
  static String _ranges(List<SeekableRange> ranges) => ranges.isEmpty
      ? 'none'
      : [
          for (final range in ranges)
            '${range.start.inSeconds}-${range.end.inSeconds}s',
        ].join(', ');

  /// The torrent rows, in the same label column as the mpv ones: what the
  /// swarm is doing right now. Null stats means the poll has not answered
  /// for this torrent yet.
  ///
  /// Three rows say three different things and the panel keeps them apart.
  /// `seeds` and `peers` are *our connections*: how many have handshaked
  /// (`live`), how many addresses the search has turned up (`seen`), and
  /// how many of the connections hold the whole file. `swarm` is not a
  /// measurement at all but what the trackers last said about everyone,
  /// which is why it carries its age -- and why it says so plainly when
  /// nobody answered, since a swarm we could not ask about is not an empty
  /// one. The phase is worth a row only while the torrent is not ready;
  /// once it is, the numbers are the news.
  static List<String> describeTorrent(TorrentStats? s) {
    if (s == null) return const ['torrent  waiting for the server'];
    return [
      if (s.phase != TorrentPhase.ready) 'torrent  ${_phase(s)}',
      'speed    ${TorrentProgressCard.formatSpeed(s.downloadSpeed)}',
      'seeds    ${s.connectedSeeders} connected',
      'peers    ${s.peerDiscovery.live} connected'
          ' / ${s.peerDiscovery.seen} found',
      'swarm    ${_swarm(s)}',
      // The single number that explains why a wait is long: nothing
      // becomes readable until a whole piece is verified.
      if (s.pieceLength case final piece?)
        'piece    ${TorrentProgressCard.formatPieceSize(piece)}',
      // ...and how far the one piece the reader is sitting on has come,
      // which is the only thing between 0 and done. `verified` is what
      // says it can be served: a full byte count on its own only means
      // it is complete enough to be hashed.
      if (s.inFlightPiece case final piece?)
        'inflight #${piece.index} · '
            '${TorrentProgressCard.formatPieceBytes(piece.downloadedBytes, piece.totalBytes)}'
            ' · ${piece.verified ? 'verified' : 'unverified'}',
    ];
  }

  /// The swarm row's numbers: what the trackers reported and how long ago,
  /// or `not reported` when none of them answered. Never a 0 in that case
  /// -- "nobody is seeding this" and "we could not ask" are different news
  /// and this is the row that has to tell them apart.
  static String _swarm(TorrentStats s) {
    final seeders = s.swarmSeeders;
    final leechers = s.swarmLeechers;
    if (seeders == null && leechers == null) return 'not reported';
    final counts = [
      if (seeders != null) '$seeders seeds',
      if (leechers != null) '$leechers peers',
    ].join(' / ');
    final age = s.swarmScrapeAge;
    return age == null ? counts : '$counts · ${formatAge(age)} ago';
  }

  /// How old a tracker scrape is, in one coarse unit: `12 s`, `4 min`,
  /// `1 h`. The panel only has to say whether the numbers are current, and
  /// the server drops anything older than an hour anyway.
  static String formatAge(Duration age) {
    if (age.inMinutes < 1) return '${age.inSeconds} s';
    if (age.inHours < 1) return '${age.inMinutes} min';
    return '${age.inHours} h';
  }

  /// The server's own reason for stopping, as its own row under the swarm,
  /// or null when the torrent is not in trouble. It is not one of
  /// [describeTorrent]'s rows because it is not one of the short ones: the
  /// text is whatever the server said, so the panel shows it in the wide
  /// row (see [_wideRow]).
  static String? describeTorrentError(TorrentStats? s) {
    final error = s?.error;
    return error == null ? null : 'error    $error';
  }

  /// The DHT row, shown only while [DhtStatus.unavailable] holds: this
  /// panel is already the details view a curious person opened, so the
  /// node counts ride along with the wording rather than sitting behind
  /// another tap. Information, never phrased as a problem -- trackers keep
  /// working regardless.
  static String describeDht(DhtStatus dht) =>
      'dht      ${DhtStatus.unavailableMessage} · ${dht.nodeCounts}';

  /// The phase, with the percentage of whatever it is measuring when the
  /// server measures one.
  static String _phase(TorrentStats s) => switch (s.phase) {
    TorrentPhase.resolvingMetadata => 'resolving metadata',
    TorrentPhase.checking => TorrentProgressCard.withPercent(
      'checking',
      s.checkProgress,
    ),
    TorrentPhase.buffering => TorrentProgressCard.withPercent(
      'buffering head',
      s.initialWindowProgress,
    ),
    TorrentPhase.ready => 'ready',
    TorrentPhase.error => 'stopped',
    TorrentPhase.unknown => 'unknown',
  };

  static String _fps(double? fps) => fps == null ? '-' : fps.toStringAsFixed(2);

  static String _hwdec(PlaybackStats s) => switch (s.isSoftwareDecoding) {
    null => '-',
    true => 'software (hwdec-current: ${s.hwdec})',
    false => s.hwdec!,
  };

  static String _cache(PlaybackStats s) {
    final duration = s.cacheDuration;
    final seconds = duration == null
        ? '-'
        : '${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
    if (s.pausedForCache == true) {
      final fill = s.cacheBufferingState;
      return '$seconds  buffering${fill == null ? '' : ' $fill%'}';
    }
    return seconds;
  }

  /// Bits per second in human units: `850 kbps`, `4.2 Mbps`.
  static String formatBitrate(int? bitsPerSecond) {
    if (bitsPerSecond == null) return '-';
    if (bitsPerSecond >= 1000000) {
      return '${(bitsPerSecond / 1000000).toStringAsFixed(1)} Mbps';
    }
    if (bitsPerSecond >= 1000) {
      return '${(bitsPerSecond / 1000).round()} kbps';
    }
    return '$bitsPerSecond bps';
  }
}
