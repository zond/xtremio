import '../../core/core.dart';
import '../details/stream_facts.dart';
import '../player/playback_stats.dart';

/// Whether a stream can be handed to a receiver as it is, repackaged, or
/// not at all, and why.
///
/// **The picture is never decoded or encoded.** A cast sends the bytes the
/// server already serves, or the same picture in another container with
/// its sound copied or converted to stereo AAC ([CastRendition]), so a
/// video codec the receiver cannot decode is not a slower cast, it is a
/// black screen. The gate therefore has to answer
/// honestly, and a refusal has to say what is wrong rather than let the
/// cast fail on the television.
///
/// What a Chromecast plays without help is an MP4 or WebM file whose video
/// is H.264, HEVC, VP8 or VP9 and whose audio is one the container is
/// allowed to carry -- AAC or MP3 in an MP4, Opus or Vorbis in a WebM. That
/// is the rule as implemented here, judged from what the app already knows:
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
/// And whatever the file is, a stream this device reads by URL through the
/// server's `/proxy` (or `/ftp`) route cannot be cast: an origin that will
/// not serve ranges, read forward, or a route the server names no media id
/// for. The LAN media listener serves published ids and nothing else, and
/// nothing here could seek such a stream for a receiver. That refusal is
/// about the URL and comes first. A stream played by id is judged on
/// `xtremio://<id>`, which names no route, and is cast by publishing it.
///
/// **Streams the receiver will not take are cast anyway: as a
/// rendition.** An H.264 or HEVC film in a Matroska or QuickTime file,
/// played by id, is [CastRendition] when this device can make one
/// (`canRepackage`): the server repackages the film's own picture into one
/// fragmented MP4 as the receiver asks for it (stream-server
/// `docs/design/renditions.md`, step F2), **with its sound copied when it
/// is AAC and converted to stereo AAC otherwise** (step F3: Dolby Digital,
/// Dolby Digital Plus, DTS, TrueHD, Opus, FLAC, MP3, PCM -- whatever mpv
/// itself decodes, the producer decodes with the same FFmpeg). **Surround is
/// converted whatever the receiver says it plays**: zond's television sends
/// its sound over Bluetooth, and a Dolby track cast to it plays silent. So
/// an MP4 or M4V whose picture the receiver takes but whose sound the
/// container does not allow (Dolby Digital in an MP4, the common case) is a
/// rendition too, not a refusal. Only mpv's word on the codecs counts for
/// a rendition -- a copy carries the picture as it is, so a release's claim
/// is not enough -- and only for a stream played by id, since the server
/// reads the film through its id. A film that would be repackaged but whose
/// picture a copy cannot carry is refused with a sentence that names it and
/// why ([CastRefusal.renditionVideo]); one whose codecs mpv has not reported
/// yet is a "not yet" ([CastRefusal.codecsPending]).
///
/// **What is judged is the film, not the container it arrived in.** When the
/// server resolved a stream to the member of an archive or a disc image,
/// that member's name is what reaches this check (`_castFilename` in the
/// player). So a `.rar` holding an MP4 is judged as the MP4 it holds.
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
    bool canRepackage = false,
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
      if (canRepackage &&
          _repackagedContainers.contains(container) &&
          mediaIdOf(url) != null) {
        return _rendition(container, stats);
      }
      return CastRefused._container(_describeContainer(container));
    }

    final video = _videoCodec(facts: facts, stats: stats);
    if (video != null && !_castableVideo.contains(video)) {
      return CastRefused._video(video, _orList(_castableVideo));
    }
    final audio = _audioCodec(facts: facts, filename: filename, stats: stats);
    if (audio != null && !format.audio.contains(audio)) {
      // An MP4 whose sound the receiver will not take (or will play
      // silent): the same picture, the sound converted.
      if (canRepackage &&
          _soundConvertedContainers.contains(container) &&
          mediaIdOf(url) != null &&
          _repackagedVideo.contains(_canonicalVideo(stats?.videoCodec)) &&
          _canonicalAudio(stats?.audioCodec) != null) {
        return const CastRendition(convertsSound: true);
      }
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

/// The stream goes to a receiver as a rendition: the same H.264 or HEVC,
/// repackaged by the server into one fragmented MP4 the receiver plays as a
/// file (`MediaIds.publishRendition`), its sound copied when it is AAC and
/// converted to stereo AAC when [convertsSound].
final class CastRendition extends CastCompatibility {
  const CastRendition({this.convertsSound = false});

  /// The sound is converted to stereo AAC (`RenditionSpec.convertSound`).
  final bool convertsSound;

  /// The MIME type of what the receiver is handed: an MP4, which it plays
  /// as a file -- not HLS, which zond's Chromecast with Google TV cannot
  /// play above 720p (stream-server `docs/design/renditions.md`, F2).
  static const String contentType = 'video/mp4';
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

  const CastRefused._video(String codec, String supported)
    : this._(
        CastRefusal.videoCodec,
        'A Chromecast decodes $supported video; this stream is $codec. '
        'Casting it would need conversion, which this app cannot do yet.',
      );

  const CastRefused._audio(String codec, String supported)
    : this._(
        CastRefusal.audioCodec,
        'A Chromecast decodes $supported; this stream is $codec. Casting it '
        'would need conversion, which this app cannot do yet.',
      );

  const CastRefused._codecsPending(String description)
    : this._(
        CastRefusal.codecsPending,
        'This stream is $description, which xtremio repackages for casting '
        'once the player has said what is in it. Try again once it has '
        'started playing.',
        title: 'Still working out what this file is',
      );

  /// A film that would be repackaged but whose picture a copy cannot
  /// carry: [sentence] names it.
  const CastRefused._rendition(CastRefusal reason, String sentence)
    : this._(reason, sentence);

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

/// Why a stream was refused. [container], [videoCodec] and [audioCodec] are
/// about a file the receiver would be handed as it is; [renditionVideo]
/// about one that would be repackaged but whose picture a copy cannot carry
/// (what a transcode, step F4 of the renditions design, would answer); a
/// rendition's sound is never refused here, since it is converted when it
/// is not AAC; [proxied] is never castable, [unknownContainer] is
/// a question rather than an answer, and [containerPending] and
/// [codecsPending] are not even that yet -- ask again when the server has
/// opened the file, or mpv has reported what is in it.
enum CastRefusal {
  proxied,
  unknownContainer,
  containerPending,
  codecsPending,
  container,
  videoCodec,
  audioCodec,
  renditionVideo,
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

/// The video codecs a receiver decodes. Unlike the table above this one is
/// a guess, and it errs in both directions rather than only the safe one.
///
/// It **leans permissive** over HEVC and VP9: only Chromecast Ultra,
/// Chromecast with Google TV and the Google TV Streamer decode HEVC, and
/// VP9 wants one of those or a Nest Hub, so a stream this gate calls ready
/// still fails on a first- to third-generation Chromecast with nothing
/// said. Fixing that honestly means asking the session what the receiver in
/// the room supports -- the Cast SDK reports the device's capabilities --
/// rather than holding one table for every device, which is a larger change
/// than any made here.
///
/// It also **leans strict** over VP8 and VP9, which is why they are in the
/// set: no WebM in the wild carries H.264, so a table of only H.264 and
/// HEVC would refuse every real WebM at the video check before the
/// container half of this file ever got a say. Written in both
/// directions, since a caveat that only leans one way hides exactly that.
///
/// And it is **not keyed on the container**, which the audio table is: a
/// WebM claiming H.264 is called ready as `video/webm`, a pair Cast lists
/// no media type for. A file that does not exist in practice, left alone
/// and named here rather than rediscovered.
const Set<String> _castableVideo = {'H.264', 'HEVC', 'VP8', 'VP9'};

/// The containers a rendition repackages out of: Matroska, the case step F2
/// of the renditions design proved, and QuickTime, which libavformat reads
/// as it reads an MP4 (its sample tables are the index the layout mirrors).
const Set<String> _repackagedContainers = {'mkv', 'mov'};

/// The containers a receiver takes whose sound it may not: an MP4 with
/// Dolby Digital or DTS is a rendition with its sound converted.
const Set<String> _soundConvertedContainers = {'mp4', 'm4v'};

/// The video a rendition copies: what the producer and the server's muxer
/// carry (`avc1`, `hvc1`), **and what the receiver decodes** -- HEVC is
/// here for zond's receiver, a Chromecast with Google TV 4K (`sabrina`),
/// which decodes HEVC Main and Main 10 up to 4K. It is a constant for that
/// one receiver until the receiver table (step F5 of the renditions design)
/// makes it a row per model; an HEVC film cast to a receiver without HEVC
/// (a first- to third-generation Chromecast) is a black screen until then.
/// Dolby Vision is not visible from here (mpv reports it as HEVC): the
/// producer copies profiles 7 and 8 as their base layer and refuses
/// profile 5 with its own sentence.
const Set<String> _repackagedVideo = {'H.264', 'HEVC'};

/// The video zond's receiver decodes, of the codecs mpv names: what tells a
/// codec it cannot play from one only the repackaging cannot carry yet.
const Set<String> _receiverVideo = {'H.264', 'HEVC', 'VP8', 'VP9'};

/// The sound a rendition copies. Anything else is converted to stereo AAC
/// (step F3). AAC with more than two channels is copied too: mpv's report
/// carries no channel count yet (step F5 adds it).
const String _repackagedAudio = 'AAC';

/// What a Matroska or QuickTime film played by id is when this device can
/// repackage: [CastRendition] when mpv reports video a copy carries -- its
/// sound copied when AAC, converted otherwise -- a sentence naming the
/// video when a copy cannot carry it, and a "not yet" while mpv has not
/// said -- a copy is only as right as the codecs it copies, so a release's
/// claim does not count.
CastCompatibility _rendition(String container, PlaybackStats? stats) {
  final video = _canonicalVideo(stats?.videoCodec);
  final audio = _canonicalAudio(stats?.audioCodec);
  if (video == null || audio == null) {
    return CastRefused._codecsPending(_describeContainer(container));
  }
  if (_repackagedVideo.contains(video)) {
    return CastRendition(convertsSound: audio != _repackagedAudio);
  }
  return CastRefused._rendition(
    CastRefusal.renditionVideo,
    _receiverVideo.contains(video)
        ? "This film's video is $video, which xtremio can't repackage for "
              'casting yet.'
        : "This film's video is $video, which this receiver can't play, and "
              "xtremio can't convert it for casting yet.",
  );
}

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
    'ac3' => 'Dolby Digital (AC3)',
    'eac3' => 'Dolby Digital Plus (E-AC3)',
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
  'Dolby Digital Plus (E-AC3)': RegExp(
    r'\bdd\+|\beac-?3\b|\bddp\b|\be-?ac-?3\b',
    caseSensitive: false,
  ),
  'Dolby Digital (AC3)': RegExp(r'\bac-?3\b|\bdd5\b', caseSensitive: false),
  'FLAC': RegExp(r'\bflac\b', caseSensitive: false),
  'Opus': RegExp(r'\bopus\b', caseSensitive: false),
  'MP3': RegExp(r'\bmp3\b', caseSensitive: false),
};

/// What a receiver takes out of [format], as the audio refusal says it:
/// "AAC or MP3 audio in an MP4 file".
String _describeAudioSupport(
  ({String contentType, String name, Set<String> audio}) format,
) => '${_orList(format.audio)} audio in ${format.name}';

/// [names] as a sentence lists them -- "AAC or MP3", "H.264, HEVC, VP8 or
/// VP9". Both refusals read their own table through this, so neither can
/// name a codec the check does not take, or miss one it does. A const set
/// literal iterates in declaration order, so the wording is the table's own
/// order and stays put.
String _orList(Iterable<String> names) {
  final items = names.toList();
  if (items.length < 2) return items.join();
  return '${items.take(items.length - 1).join(', ')} or ${items.last}';
}

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
/// a converted stream knows better is a kept download, where the app builds
/// a `url` stream on the server's media route -- and a `url` stream has no
/// torrent behind it as far as the core is concerned, so [serverFilename]
/// is null there and the order never comes up.
String? castFilename(PlayerState? state, {String? serverFilename}) =>
    serverFilename ??
    state?.convertedStream?.filename ??
    state?.selectedStream?.filename;
