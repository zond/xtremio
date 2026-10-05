import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../cast/cast_client.dart';
import 'playback_stats_overlay.dart';
import 'time_format.dart';
import 'torrent_stats.dart';

/// What the player knew about a cast when it handed it over: who the
/// receiver is, what the compatibility check judged, how the film is sent,
/// and mpv's word on the sound it was playing. Everything the server's
/// numbers do not say.
@immutable
final class CastFacts {
  const CastFacts({
    required this.deviceName,
    this.model,
    this.video,
    this.tentative = false,
    this.direct = false,
    this.rendition = false,
    this.convertsSound = false,
    this.sourceAudio,
    this.sourceChannels,
    this.reportsPicture = false,
  });

  /// What the receiver calls itself, and the model name it announced.
  final String deviceName;
  final String? model;

  /// The picture's codec as the check judged it (`HEVC`), null for sound
  /// alone; and whether only some models announcing [model] decode it, so
  /// the cast is a trial rather than a certainty (`ReceiverTable`).
  final String? video;
  final bool tentative;

  /// The receiver fetches the stream from its source itself: nothing is
  /// served from this device, so the server has no numbers for it.
  final bool direct;

  /// The receiver is sent the server's rendition, its sound converted when
  /// [convertsSound].
  final bool rendition;
  final bool convertsSound;

  /// The sound mpv was playing (`audio-codec-name`) and its channels as the
  /// container declares them.
  final String? sourceAudio;
  final int? sourceChannels;

  /// The platform reports what picture the receiver shows: without that a
  /// missing report says nothing.
  final bool reportsPicture;
}

/// **How often the receiver stopped to buffer since the cast began, and for
/// how long in all**, from the states it reports. The load is not a stop:
/// counting starts at the first report of playing or paused. A stop still
/// going counts up to [totalAt]'s now.
@immutable
final class CastBuffering {
  const CastBuffering({
    this.count = 0,
    this.total = Duration.zero,
    this.since,
    this.started = false,
  });

  final int count;

  /// The stops that have ended, added up.
  final Duration total;

  /// When the stop under way began; null while it plays.
  final DateTime? since;

  /// The receiver has played (or paused) since the load.
  final bool started;

  /// The receiver reported [state] at [at].
  CastBuffering note(CastPlayerState state, DateTime at) {
    final since = this.since;
    if (state == CastPlayerState.buffering) {
      if (!started || since != null) return this;
      return CastBuffering(
        count: count + 1,
        total: total,
        since: at,
        started: true,
      );
    }
    return CastBuffering(
      count: count,
      total: since == null ? total : total + at.difference(since),
      started:
          started ||
          state == CastPlayerState.playing ||
          state == CastPlayerState.paused,
    );
  }

  /// Every stop added up, the one under way to [now].
  Duration totalAt(DateTime now) {
    final since = this.since;
    return since == null ? total : total + now.difference(since);
  }
}

/// One answer of the server's, and when it came.
typedef CastSample = ({DateTime at, CastNumbers numbers});

/// **The stats panel while a receiver has the film**: drawn on the phone's
/// casting view, never sent to the receiver. The look of
/// [PlaybackStatsOverlay] -- its text, its box, a row only where there is a
/// reading -- with what a cast is judged by: the receiver and what it says
/// it shows, what it is sent, how often it stopped, how often it asked
/// this device for the film and how fast it is taking it, and for a
/// rendition how far ahead of it the film is made.
///
/// **Polls [numbers] while it is mounted and the app is in front**, every
/// [interval], and at no other time: the player mounts it only while a cast
/// is live and the panel is on, and it listens for the app being hidden
/// itself -- a hidden app draws no frames, so no rebuild would come to tell
/// it. Every rate is two answers over the time between them by [now],
/// which a test winds; the server keeps no clock for them.
class CastStatsOverlay extends StatefulWidget {
  const CastStatsOverlay({
    super.key,
    required this.facts,
    required this.status,
    required this.buffering,
    required this.now,
    this.numbers,
    this.isTorrent = false,
    this.torrent,
    this.interval = pollInterval,
  });

  /// How often the server is asked.
  static const Duration pollInterval = Duration(seconds: 1);

  /// The window the re-request count covers: a healthy receiver asks once
  /// per seek, so more than a few here is a receiver in trouble.
  static const Duration requestWindow = Duration(seconds: 30);

  final CastFacts facts;
  final CastStatus status;
  final CastBuffering buffering;
  final DateTime Function() now;

  /// What the publication has served, asked once a tick; null for a cast
  /// this device serves nothing for ([CastFacts.direct]).
  final CastNumbers? Function()? numbers;

  /// The torrent's own rows ([PlaybackStatsOverlay.describeTorrent]), from
  /// the player's poll, for a film a torrent is behind.
  final bool isTorrent;
  final TorrentStats? torrent;

  final Duration interval;

  /// One text line per reading, in the panel's order. [samples] are the
  /// server's answers, oldest first; the rates take the last two, the
  /// re-request count the window back from the last.
  static List<String> describe({
    required CastFacts facts,
    required CastStatus status,
    required CastBuffering buffering,
    required DateTime now,
    List<CastSample> samples = const [],
    bool isTorrent = false,
    TorrentStats? torrent,
  }) {
    final latest = samples.isEmpty ? null : samples.last;
    final before = samples.length < 2 ? null : samples[samples.length - 2];
    final numbers = latest?.numbers;
    final made = numbers?.made;
    final seconds = before == null
        ? 0.0
        : latest!.at.difference(before.at).inMicroseconds / 1e6;
    // Per second, between the last two answers; null with one, or with no
    // time between them.
    double? rate(int Function(CastNumbers numbers) count) => seconds <= 0
        ? null
        : (count(latest!.numbers) - count(before!.numbers)) / seconds;
    final duration = status.duration;
    final sent = rate((numbers) => numbers.delivery.bytes);
    final read = rate((numbers) => numbers.source.bytesRead);
    final filmMade = rate(
      (numbers) => numbers.made?.filmMade.inMilliseconds ?? 0,
    );
    final madeTo = made?.madeTo;
    return [
      'receiver ${[facts.deviceName, ?facts.model, if (facts.video case final video?) '$video ${facts.tentative ? 'tried' : 'sent'}', _state(status), if (status.picture case final picture?) '$picture' else if (facts.reportsPicture) 'no picture reported'].join(' · ')}',
      'sending  ${_sending(facts, numbers)}',
      'position ${duration == null ? formatTime(status.position) : '${formatTime(status.position)} / ${formatTime(duration)}'}',
      'buffered ${buffering.count == 0 ? 'never' : '${buffering.count} ${buffering.count == 1 ? 'time' : 'times'} · ${_seconds(buffering.totalAt(now))}'}',
      if (numbers != null) ...[
        'requests ${numbers.delivery.requests} · '
            '${numbers.delivery.bodiesBegun} '
            '${numbers.delivery.bodiesBegun == 1 ? 'body' : 'bodies'} · '
            '${numbers.delivery.bodiesOpen} open',
        ?_reRequests(samples),
        'sent     ${formatBytes(numbers.delivery.bytes)}'
            '${sent == null ? '' : ' · ${PlaybackStatsOverlay.formatBitrate((sent * 8).round())}'}',
      ],
      if (made != null) ...[
        if (_halves([
              if (madeTo != null)
                '${_seconds(madeTo - status.position < Duration.zero ? Duration.zero : madeTo - status.position)} ahead',
              if (filmMade != null && filmMade > 0)
                '${(filmMade / 1000).toStringAsFixed(1)}x',
            ])
            case final line?)
          'made     $line',
        'runs     ${[for (final run in made.runs) 'at ${run.from == null ? '?' : formatTime(run.from!)}, ${run.produced} ${run.produced == 1 ? 'slot' : 'slots'}', if (made.runs.isEmpty) 'none live', '${made.runsStarted} started'].join(' · ')}',
        if (made.slots case final slots?)
          'layout   $slots slots'
              '${made.slotLength == null ? '' : ' of ${_seconds(made.slotLength!)}'}'
              '${made.exact == null ? '' : ', ${made.exact! ? 'exact' : 'estimated'}'}',
      ],
      if (numbers != null && numbers.source.kind != null)
        'source   ${[numbers.source.kind!, if (read != null) PlaybackStatsOverlay.formatBitrate((read * 8).round()), '${numbers.source.opens} ${numbers.source.opens == 1 ? 'open' : 'opens'}', '${numbers.source.seeks} ${numbers.source.seeks == 1 ? 'seek' : 'seeks'}'].join(' · ')}',
      if (isTorrent) ...PlaybackStatsOverlay.describeTorrent(torrent),
    ];
  }

  /// What the receiver is doing, in the words of its report.
  static String _state(CastStatus status) => switch (status.state) {
    CastPlayerState.playing => 'playing',
    CastPlayerState.paused => 'paused',
    CastPlayerState.buffering => 'buffering',
    CastPlayerState.idle when status.ended => 'idle, finished',
    CastPlayerState.idle when status.failed => 'idle, failed',
    CastPlayerState.idle => 'idle',
  };

  /// How the film goes to the receiver: from its source, as it is, or as
  /// the server's rendition -- and what of the picture and the sound is
  /// copied or converted, from the server's answer where it has one and
  /// from what was decided at the hand-over where it does not.
  static String _sending(CastFacts facts, CastNumbers? numbers) {
    if (facts.direct) return 'from its source, not through this device';
    final made = numbers?.made;
    final rendition = numbers?.rendition ?? facts.rendition;
    final type = numbers?.contentType ?? (rendition ? 'video/mp4' : null);
    final source = _halves([
      ?facts.sourceAudio,
      if (facts.sourceChannels case final channels?) _channels(channels),
    ], separator: ' ');
    final video = made?.videoCodec ?? facts.video?.toLowerCase();
    final String? sound;
    if (!rendition) {
      sound = source;
    } else if (made?.soundConverted ?? facts.convertsSound) {
      final out = [
        made?.soundCodec ?? 'aac',
        _channels(made?.soundChannels ?? 2),
        if (made?.soundBitrate case final bitrate?)
          PlaybackStatsOverlay.formatBitrate(bitrate),
      ].join(' ');
      sound = source == null ? '→ $out' : '$source → $out';
    } else {
      sound = source == null ? 'copied' : '$source copied';
    }
    return [
      rendition
          ? 'rendition ($type)'
          : type == null
          ? 'as it is'
          : 'as it is ($type)',
      if (video != null)
        'video $video${rendition && (made?.videoCopied ?? true) ? ' copied' : ''}',
      if (sound != null) 'audio $sound',
    ].join(' · ');
  }

  /// A channel count as a layout: `2.0`, `5.1`, `7.1`.
  static String _channels(int channels) => switch (channels) {
    1 => 'mono',
    2 => '2.0',
    6 => '5.1',
    8 => '7.1',
    _ => '$channels ch',
  };

  /// The requests in the last [requestWindow] -- or in as much of it as
  /// the panel has watched, said as such. Null before two answers.
  static String? _reRequests(List<CastSample> samples) {
    if (samples.length < 2) return null;
    final latest = samples.last;
    final from = latest.at.subtract(requestWindow);
    final base = samples.lastWhere(
      (sample) => !sample.at.isAfter(from),
      orElse: () => samples.first,
    );
    final span = latest.at.difference(base.at);
    if (span <= Duration.zero) return null;
    final count =
        latest.numbers.delivery.requests - base.numbers.delivery.requests;
    final over = span >= requestWindow
        ? requestWindow.inSeconds
        : span.inSeconds;
    return 're-req.  $count in the last $over s';
  }

  /// Seconds to a tenth under ten, coarser above
  /// ([PlaybackStatsOverlay.formatAge]).
  static String _seconds(Duration duration) => duration.inSeconds < 10
      ? '${(duration.inMilliseconds / 1000).toStringAsFixed(1)} s'
      : PlaybackStatsOverlay.formatAge(duration);

  static String? _halves(List<String> halves, {String separator = ' · '}) =>
      halves.isEmpty ? null : halves.join(separator);

  @override
  State<CastStatsOverlay> createState() => _CastStatsOverlayState();
}

class _CastStatsOverlayState extends State<CastStatsOverlay> {
  Timer? _timer;
  late final AppLifecycleListener _lifecycle;
  bool _hidden = false;

  /// The server's answers, oldest first: the newest at or before the
  /// re-request window's start and every one after it.
  final List<CastSample> _samples = [];

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () {
        _hidden = true;
        _sync();
      },
      onShow: () {
        _hidden = false;
        _sync();
        if (mounted) setState(() {});
      },
    );
    _sync();
  }

  @override
  void didUpdateWidget(CastStatsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.numbers == null) != (widget.numbers == null)) _sync();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _timer?.cancel();
    super.dispose();
  }

  /// Polls while there is something to ask and the panel is being looked
  /// at, and not otherwise. Coming back starts the history again: a rate
  /// across the time the app was away is no reading of now.
  void _sync() {
    final polling = !_hidden && widget.numbers != null;
    if (!polling) {
      _timer?.cancel();
      _timer = null;
      _samples.clear();
      return;
    }
    if (_timer != null) return;
    _timer = Timer.periodic(widget.interval, (_) => setState(_ask));
    // At once rather than in a second: whoever just opened the panel wants
    // the numbers now. A build follows every caller.
    _ask();
  }

  /// One ask, recorded: an answer of none (the token is gone) clears the
  /// history, and only the answers the re-request window still needs are
  /// kept.
  void _ask() {
    final ask = widget.numbers;
    if (ask == null) return;
    CastNumbers? numbers;
    try {
      numbers = ask();
    } on Object {
      numbers = null;
    }
    if (numbers == null) {
      _samples.clear();
      return;
    }
    final at = widget.now();
    _samples.add((at: at, numbers: numbers));
    final from = at.subtract(CastStatsOverlay.requestWindow);
    while (_samples.length > 2 && !_samples[1].at.isAfter(from)) {
      _samples.removeAt(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = PlaybackStatsOverlay.styleOf(context);
    return PlaybackStatsOverlay.box([
      for (final line in CastStatsOverlay.describe(
        facts: widget.facts,
        status: widget.status,
        buffering: widget.buffering,
        now: widget.now(),
        samples: _samples,
        isTorrent: widget.isTorrent,
        torrent: widget.torrent,
      ))
        Text(line, style: style),
    ]);
  }
}
