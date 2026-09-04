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
/// is H.264 or HEVC and whose audio is one the container is allowed to
/// carry -- AAC or MP3 in an MP4, Opus or Vorbis in a WebM. That is the
/// rule as implemented here, judged from what the app already knows:
///
/// - the **container** from the best filename known (see [castFilename]:
///   the file the *server* says it opened, then the converted stream's,
///   then `behaviorHints.filename`), or failing that a URL path that ends
///   in a real file name. A torrent's streaming URL is
///   `/{infoHash}/{fileIdx}` and carries no extension, so a filename is the
///   only source — and an unknown container is a refusal, not a maybe: a
///   guess here is a guess about whether the evening works. The one thing
///   that is not a refusal is a torrent whose server has not named the file
///   *yet*; that is [CastRefusal.containerPending], a "not yet" rather than
///   a "no".
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
  /// filename known ([castFilename]), and [stats] mpv's last report while
  /// playing this locally, when there is one. [containerPending] says that
  /// a filename may still arrive -- a torrent whose stats have not named
  /// the file the server opened -- which turns the unknown container from a
  /// verdict into a wait.
  factory CastCompatibility.of({
    required Uri url,
    StreamFacts? facts,
    String? filename,
    PlaybackStats? stats,
    bool containerPending = false,
  }) {
    final proxied = _proxyPrefix(url);
    if (proxied != null) return CastRefused._proxy(proxied);

    final container = _containerOf(filename) ?? _containerOf(_urlFilename(url));
    if (container == null) {
      return containerPending
          ? const CastRefused._containerPending()
          : const CastRefused._unknownContainer();
    }
    final format = _castableContainers[container];
    if (format == null) {
      return CastRefused._container(_describeContainer(container));
    }

    final video = _videoCodec(facts: facts, stats: stats);
    if (video != null && !_castableVideo.contains(video)) {
      return CastRefused._video(video);
    }
    final audio = _audioCodec(facts: facts, filename: filename, stats: stats);
    if (audio != null && !format.audio.contains(audio)) {
      return CastRefused._audio(audio, _describeAudioSupport(format));
    }
    return CastReady(contentType: format.contentType);
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
  const CastRefused._(this.reason, this.explanation, {this.title});

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

  const CastRefused._containerPending()
    : this._(
        CastRefusal.containerPending,
        'The server has not said yet which file this torrent streams, so '
        'there is no telling what kind of file it is. It knows once the '
        'torrent has started; try again in a moment.',
        // The one refusal that is not a verdict, so it does not get to be
        // headed like one.
        title: 'Still working out what this file is',
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

  const CastRefused._audio(String codec, String supported)
    : this._(
        CastRefusal.audioCodec,
        'A Chromecast decodes $supported; this stream is $codec. Casting it '
        'would need conversion, which this app cannot do yet.',
      );

  /// Which rule refused, for the tests and for whatever later decides that
  /// a particular refusal is the one Media3 could remux around.
  final CastRefusal reason;

  /// The heading over [explanation], or null for the dialog's own -- which
  /// says the stream cannot be cast, and is right for every refusal that is
  /// an answer.
  final String? title;

  /// What to put in front of the viewer. Says what is wrong and that the
  /// conversion which would fix it is not built, rather than "cannot cast".
  final String explanation;
}

/// Why a stream was refused. The seam for Media3: [container], [videoCodec]
/// and [audioCodec] are the three a remux could answer, [proxied] never is,
/// [unknownContainer] is a question rather than an answer, and
/// [containerPending] is not even that yet -- ask again when the server has
/// opened the file.
enum CastRefusal {
  proxied,
  unknownContainer,
  containerPending,
  container,
  videoCodec,
  audioCodec,
}

/// The file extensions a receiver plays: the MIME type to declare, how a
/// sentence names the file, and the audio it may carry.
///
/// The audio hangs off the container because that is where the receiver
/// draws the line -- an MP3 track plays out of an MP4 and not out of a
/// WebM, and Opus the other way round -- so one flat list of codecs was
/// wrong whichever codecs it held.
const Map<String, ({String contentType, String name, Set<String> audio})>
_castableContainers = {
  'mp4': (contentType: 'video/mp4', name: 'an MP4 file', audio: {'AAC', 'MP3'}),
  'm4v': (contentType: 'video/mp4', name: 'an M4V file', audio: {'AAC', 'MP3'}),
  'webm': (
    contentType: 'video/webm',
    name: 'a WebM file',
    audio: {'Opus', 'Vorbis'},
  ),
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

/// The video codecs a receiver decodes -- and unlike the table above, this
/// one is a guess that leans permissive. Only Chromecast Ultra, Chromecast
/// with Google TV and the Google TV Streamer decode HEVC; a first- to
/// third-generation Chromecast and a Nest Hub take H.264 and VP8 only, so
/// an HEVC stream this gate calls ready fails on those receivers with
/// nothing said. Fixing it honestly means asking the session what the
/// receiver in the room supports -- the Cast SDK reports the device's
/// capabilities -- rather than holding one table for every device, and
/// that is a larger change than this one.
const Set<String> _castableVideo = {'H.264', 'HEVC'};

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

/// What a receiver takes out of [format], as the audio refusal says it:
/// "AAC or MP3 audio in an MP4 file".
String _describeAudioSupport(
  ({String contentType, String name, Set<String> audio}) format,
) => '${format.audio.join(' or ')} audio in ${format.name}';

/// The name of the container [extension] belongs to, for a refusal that
/// says what the file is rather than repeating the three letters.
String _describeContainer(String extension) =>
    _knownContainers[extension] ?? 'a .$extension file';

/// The filename the check should read, first hit wins: [serverFilename],
/// then the converted stream's, then the selected stream's
/// `behaviorHints.filename`, then nothing.
///
/// [serverFilename] is `TorrentStats.streamName`, the file the embedded
/// server actually opened, and it comes first on purpose. The addon says
/// what it believes it linked to and is often silent; the server says what
/// it is serving, and for a torrent stream whose URL is
/// `/{infoHash}/{fileIdx}` it is the only thing that ever names the file.
///
/// It outranks the converted stream too, because for a torrent the two are
/// the same claim: `Stream::to_converted` clones `behavior_hints` verbatim,
/// so a converted stream's filename is the addon's filename. The one place
/// a converted stream knows better is an offline play, where the app builds
/// the stream from the file on disk -- and that is a `url` stream with no
/// torrent behind it, so [serverFilename] is null there and the order never
/// comes up.
String? castFilename(PlayerState? state, {String? serverFilename}) =>
    serverFilename ??
    state?.convertedStream?.filename ??
    state?.selectedStream?.filename;
