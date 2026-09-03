import '../../core/core.dart';
import '../details/stream_facts.dart';
import '../player/playback_stats.dart';

/// Whether a stream can be handed to a receiver as it is, and if not, why.
///
/// **There is no conversion.** This step of casting sends the bytes the
/// server already serves, so a file the receiver cannot decode is not a
/// slower cast, it is a black screen. The gate therefore has to answer
/// honestly, and a refusal has to say what is wrong rather than let the
/// cast fail on the television.
///
/// What a Chromecast plays without help is an MP4 or WebM file whose video
/// is H.264 or HEVC and whose audio is AAC. That is the rule as implemented
/// here, judged from what the app already knows:
///
/// - the **container** from `behaviorHints.filename` (or the converted
///   stream's, or a URL path that ends in a real file name). A torrent's
///   streaming URL is `/{infoHash}/{fileIdx}` and carries no extension, so
///   the filename is usually the only source — and an unknown container is
///   a refusal, not a maybe: a guess here is a guess about whether the
///   evening works.
/// - the **codecs** from mpv, when this stream is playing locally and has
///   reported them, and otherwise from what the release says about itself
///   ([StreamFacts]'s tags, and the filename). Those are *claims*, so they
///   are believed when they say something is wrong and never taken as proof
///   that something is right: a codec nothing mentions passes the gate on
///   the container's strength alone.
///
/// And whatever the file is, a stream stremio-core plays through the
/// server's `/proxy` (or `/ftp`) route cannot be cast at all: those routes
/// are deliberately not mounted on the LAN media listener, because each is
/// an open proxy and the local network is not the loopback interface. That
/// refusal is about the URL and comes first.
sealed class CastCompatibility {
  const CastCompatibility();

  /// The result of judging [url] with everything known about it.
  ///
  /// [facts] is what the stream said about itself, [filename] the best
  /// filename known (the converted stream's included), and [stats] mpv's
  /// last report while playing this locally, when there is one.
  factory CastCompatibility.of({
    required Uri url,
    StreamFacts? facts,
    String? filename,
    PlaybackStats? stats,
  }) {
    final proxied = _proxyPrefix(url);
    if (proxied != null) return CastRefused._proxy(proxied);

    final container = _containerOf(filename) ?? _containerOf(_urlFilename(url));
    if (container == null) return const CastRefused._unknownContainer();
    if (!_castableContainers.containsKey(container)) {
      return CastRefused._container(_describeContainer(container));
    }

    final video = _videoCodec(facts: facts, stats: stats);
    if (video != null && !_castableVideo.contains(video)) {
      return CastRefused._video(video);
    }
    final audio = _audioCodec(facts: facts, filename: filename, stats: stats);
    if (audio != null && !_castableAudio.contains(audio)) {
      return CastRefused._audio(audio);
    }
    return CastReady(contentType: _castableContainers[container]!);
  }

  /// Whether the stream can be cast as it is.
  bool get isReady => this is CastReady;
}

/// The stream can go to a receiver untouched.
final class CastReady extends CastCompatibility {
  const CastReady({required this.contentType});

  /// The MIME type to tell the receiver, e.g. `video/mp4`.
  final String contentType;
}

/// The stream cannot go to a receiver as it is, with the sentence to show.
final class CastRefused extends CastCompatibility {
  const CastRefused._(this.reason, this.explanation);

  const CastRefused._proxy(String prefix)
    : this._(
        CastRefusal.proxied,
        'This stream is played through the app\'s own $prefix proxy, which '
        'is never opened to the local network. It cannot be cast.',
      );

  const CastRefused._unknownContainer()
    : this._(
        CastRefusal.unknownContainer,
        'Nothing here says what kind of file this stream is, so there is no '
        'telling whether a Chromecast could play it. Casting it would need '
        'conversion, which this app cannot do yet.',
      );

  const CastRefused._container(String description)
    : this._(
        CastRefusal.container,
        'A Chromecast plays MP4 and WebM files; this stream is $description. '
        'Casting it would need conversion, which this app cannot do yet.',
      );

  const CastRefused._video(String codec)
    : this._(
        CastRefusal.videoCodec,
        'A Chromecast decodes H.264 and HEVC video; this stream is $codec. '
        'Casting it would need conversion, which this app cannot do yet.',
      );

  const CastRefused._audio(String codec)
    : this._(
        CastRefusal.audioCodec,
        'A Chromecast decodes AAC audio; this stream is $codec. Casting it '
        'would need conversion, which this app cannot do yet.',
      );

  /// Which rule refused, for the tests and for whatever later decides that
  /// a particular refusal is the one Media3 could remux around.
  final CastRefusal reason;

  /// What to put in front of the viewer. Says what is wrong and that the
  /// conversion which would fix it is not built, rather than "cannot cast".
  final String explanation;
}

/// Why a stream was refused. The seam for Media3: [container], [videoCodec]
/// and [audioCodec] are the three a remux could answer, [proxied] never is,
/// and [unknownContainer] is a question rather than an answer.
enum CastRefusal {
  proxied,
  unknownContainer,
  container,
  videoCodec,
  audioCodec,
}

/// The file extensions a receiver plays, and the MIME type to declare.
const Map<String, String> _castableContainers = {
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'webm': 'video/webm',
};

/// Extensions that are containers we recognise but a receiver will not take.
/// Anything not here and not castable is still refused — this list only
/// exists so the sentence can name the format instead of the extension.
const Map<String, String> _knownContainers = {
  'mkv': 'a Matroska (.mkv) file',
  'avi': 'an AVI file',
  'ts': 'an MPEG transport stream',
  'm2ts': 'an MPEG transport stream',
  'mov': 'a QuickTime (.mov) file',
  'wmv': 'a Windows Media file',
  'flv': 'a Flash video file',
  'ogv': 'an Ogg video file',
  'mpg': 'an MPEG program stream',
  'mpeg': 'an MPEG program stream',
  '3gp': 'a 3GP file',
  'rmvb': 'a RealMedia file',
  'divx': 'a DivX file',
};

const Set<String> _castableVideo = {'H.264', 'HEVC'};
const Set<String> _castableAudio = {'AAC'};

/// The `/proxy` or `/ftp` prefix [url] is served under, or null.
///
/// Matched on the path's first segment, whatever host it is on: this is
/// about what the URL asks the server to *do*, and a URL pointing at
/// another Stremio server's proxy is no more castable than one pointing at
/// ours.
String? _proxyPrefix(Uri url) {
  final first = url.pathSegments.isEmpty ? null : url.pathSegments.first;
  return switch (first) {
    'proxy' => '/proxy',
    'ftp' => '/ftp',
    _ => null,
  };
}

/// The last path segment of [url] when it looks like a file name. A
/// torrent's `/{infoHash}/{fileIdx}` has no extension and yields null,
/// which is what sends the check to `behaviorHints.filename`.
String? _urlFilename(Uri url) {
  final segments = url.pathSegments;
  if (segments.isEmpty) return null;
  final last = segments.last;
  return last.contains('.') ? last : null;
}

/// The lower-case extension of [filename], or null when there is none to
/// read. A trailing dot, a bare name and a name whose "extension" is not
/// letters and digits all count as nothing known.
String? _containerOf(String? filename) {
  if (filename == null) return null;
  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) return null;
  final extension = filename.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{2,5}$').hasMatch(extension) ? extension : null;
}

/// The video codec, mpv's word first and the release's claim second, or
/// null when nothing said.
String? _videoCodec({StreamFacts? facts, PlaybackStats? stats}) {
  final reported = _canonicalVideo(stats?.videoCodec);
  if (reported != null) return reported;
  // StreamFacts already reads the name, the filename, the binge group and
  // the description for these; a claim about the codec is the same claim
  // wherever it was written.
  final tags = facts?.tags ?? const [];
  if (tags.contains('HEVC')) return 'HEVC';
  if (tags.contains('AVC')) return 'H.264';
  if (tags.contains('AV1')) return 'AV1';
  return null;
}

/// mpv's `video-codec` (`h264 (High)`, `hevc (Main 10)`) as a name the
/// sentence can use; null when mpv said nothing.
String? _canonicalVideo(String? codec) {
  if (codec == null) return null;
  final text = codec.toLowerCase();
  if (text.startsWith('h264') || text.startsWith('avc')) return 'H.264';
  if (text.startsWith('hevc') || text.startsWith('h265')) return 'HEVC';
  if (text.startsWith('av1')) return 'AV1';
  if (text.startsWith('vp9')) return 'VP9';
  if (text.startsWith('vp8')) return 'VP8';
  if (text.startsWith('mpeg4')) return 'MPEG-4 Part 2';
  if (text.startsWith('mpeg2')) return 'MPEG-2';
  // Something we have no name for, reported by the decoder that is playing
  // it: the first word is the codec, and it is not one of ours.
  return codec.split(RegExp(r'[\s(]')).first;
}

/// The audio codec, mpv's word first and then what the release text says.
String? _audioCodec({
  StreamFacts? facts,
  String? filename,
  PlaybackStats? stats,
}) {
  final reported = _canonicalAudio(stats?.audioCodec);
  if (reported != null) return reported;
  final tags = facts?.tags ?? const [];
  // StreamFacts recognises these two, and neither is AAC.
  if (tags.contains('Atmos')) return 'Dolby Atmos';
  if (tags.contains('DTS')) return 'DTS';
  // The rest are not badges anyone wants on a stream row, so they are read
  // here: the filename first, then whatever else names the release.
  final text =
      '${filename ?? ''}\n${facts?.filename ?? ''}\n'
      '${facts?.releaseTag ?? ''}';
  for (final MapEntry(key: label, value: pattern) in _audioPatterns.entries) {
    if (pattern.hasMatch(text)) return label;
  }
  return null;
}

/// mpv's `audio-codec-name` (`aac`, `eac3`, `dts`) as a name to show.
String? _canonicalAudio(String? codec) {
  if (codec == null) return null;
  return switch (codec.toLowerCase().trim()) {
    '' => null,
    'aac' || 'aac_latm' => 'AAC',
    'ac3' => 'Dolby Digital',
    'eac3' => 'Dolby Digital Plus',
    'truehd' => 'Dolby TrueHD',
    'dts' => 'DTS',
    'mp3' => 'MP3',
    'flac' => 'FLAC',
    'opus' => 'Opus',
    'vorbis' => 'Vorbis',
    final other => other.toUpperCase(),
  };
}

/// Audio codecs a release name spells out, canonical label first. AAC is in
/// here so a filename that says so answers before the ones below it.
final Map<String, RegExp> _audioPatterns = {
  'AAC': RegExp(r'\baac\b', caseSensitive: false),
  'Dolby TrueHD': RegExp(r'\btrue-?hd\b', caseSensitive: false),
  'Dolby Digital Plus': RegExp(
    r'\bdd\+|\beac-?3\b|\bddp\b|\be-?ac-?3\b',
    caseSensitive: false,
  ),
  'Dolby Digital': RegExp(r'\bac-?3\b|\bdd5\b', caseSensitive: false),
  'FLAC': RegExp(r'\bflac\b', caseSensitive: false),
  'Opus': RegExp(r'\bopus\b', caseSensitive: false),
  'MP3': RegExp(r'\bmp3\b', caseSensitive: false),
};

/// The name of the container [extension] belongs to, for a refusal that
/// says what the file is rather than repeating the three letters.
String _describeContainer(String extension) =>
    _knownContainers[extension] ?? 'a .$extension file';

/// What to call the media on the receiver, and the filename the check
/// should read: the converted stream's, the selected stream's, or nothing.
String? castFilename(PlayerState? state) =>
    state?.convertedStream?.filename ?? state?.selectedStream?.filename;
