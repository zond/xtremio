import '../../core/core.dart';
import '../player/playback_stats.dart';
import 'receiver_table.dart';

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
/// **mpv is the only authority on what the file is** (zond, 2026-10-05:
/// "always use the mpv info"). A cast starts from the player, where mpv is
/// reading the file, so its report ([PlaybackStats.fileFormat],
/// `videoCodec`, `audioCodec`) is about the file itself. A file name, a
/// URL's extension and what a release says of itself (`x265`, `DDP5.1`)
/// are claims, often absent -- a debrid link names no file at all -- and
/// sometimes wrong, so none of them is read here. Until mpv has reported,
/// the answer is a "not yet" ([CastRefusal.pending]), never a guess.
///
/// What a Chromecast plays without help is an MP4 or WebM file whose video
/// its model decodes ([ReceiverRow]: H.264 everywhere, HEVC, VP8, VP9 and
/// AV1 on some, each up to a size and rate) and whose audio is one the
/// container is allowed to carry -- AAC or MP3 in an MP4, Opus or Vorbis in a WebM. mpv
/// names the reader that opened the file, and a reader opens a family:
///
/// - **the MP4 family** (`mov,mp4,m4a,3gp,3g2,mj2`: MP4, M4V, QuickTime)
///   goes as `video/mp4` when its codecs are ones the receiver takes;
/// - **the Matroska family** (`mkv`, `matroska,webm`) is a WebM when its
///   codecs are WebM's -- VP8 or VP9 with Opus or Vorbis -- and goes as
///   `video/webm`; with anything else it is a Matroska file, which a
///   receiver does not take as it is;
/// - anything else (AVI, a transport stream) no receiver takes.
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
/// rendition.** An H.264 or HEVC film in a Matroska file, played by id, is
/// [CastRendition] when this device can make one (`canRepackage`): the
/// server repackages the film's own picture into one fragmented MP4 as the
/// receiver asks for it (stream-server `docs/design/renditions.md`, step
/// F2), **with its sound copied when it is AAC in one or two channels and
/// converted to stereo AAC otherwise** (step F3: Dolby Digital, Dolby
/// Digital Plus, DTS, TrueHD, Opus, FLAC, MP3, PCM, AAC 5.1 -- whatever mpv
/// itself decodes, the producer decodes with the same FFmpeg). **Surround
/// is converted whatever the receiver says it plays**: zond's television
/// sends its sound over Bluetooth, and a Dolby track cast to it plays
/// silent. So a file of the MP4 family whose picture the receiver takes but
/// whose sound the container does not allow (Dolby Digital in an MP4, the
/// common case), or allows in more than two channels (AAC 5.1), is a
/// rendition too, not a refusal or a gamble. A rendition is only for a stream played by
/// id, since the server reads the film through its id. A film that would be
/// repackaged but whose picture a copy cannot carry is refused with a
/// sentence that names it and why ([CastRefusal.renditionVideo]).
///
/// **What is judged is the film, not the container it arrived in.** mpv
/// reads the member of an archive or a disc image, not the archive, so a
/// `.rar` holding an MP4 is judged as the MP4 it holds.
sealed class CastCompatibility {
  const CastCompatibility();

  /// The result of judging [url] by [stats], mpv's last report while
  /// playing it here; null, or one that does not name the file's format
  /// and its video yet, is a "not yet".
  ///
  /// [receiver] is what the receiver being cast to decodes
  /// ([ReceiverTable.of]): a film whose picture it does not decode, or
  /// decodes only smaller or slower, is refused with a sentence saying what
  /// it plays -- as it is or as a rendition alike, since a rendition copies
  /// the picture.
  ///
  /// **A receiver known only by its name is tried, not refused**, with
  /// what the best model announcing that name decodes
  /// ([ReceiverRow.atBest]): the answer is then [tentative], and the player
  /// watches the receiver's own report of the picture to catch one that
  /// plays the sound over a black screen. A receiver identified as unable
  /// is refused.
  ///
  /// A file mpv reads no video track in at all (audio alone) is judged by
  /// its container and sound.
  factory CastCompatibility.of({
    required Uri url,
    required ReceiverRow receiver,
    PlaybackStats? stats,
    bool canRepackage = false,
  }) {
    final proxied = _proxyPrefix(url);
    if (proxied != null) return CastRefused._proxy(proxied);

    final readers = stats?.fileFormat?.split(',');
    final video = _canonicalVideo(stats?.videoCodec);
    final audio = _canonicalAudio(stats?.audioCodec);
    // No video track, as the demuxer that named the reader says, and the
    // sound decoding: a file of sound alone, not a picture still to come.
    final soundAlone =
        readers != null &&
        video == null &&
        stats?.videoTrack == null &&
        audio != null;
    if (readers == null || (video == null && !soundAlone)) {
      return const CastRefused._pending();
    }
    if (video == null) return _soundAlone(readers, audio!);

    final surround = (stats?.audioChannels ?? 0) > 2;
    final repackages = canRepackage && mediaIdOf(url) != null;
    // What the receiver makes of the picture: null when it shows it. One
    // known only by name is held to the best model with that name, and a
    // cast that needs more than every such model decodes is a trial.
    final best = receiver.atBest;
    final known = _pictureRefusal(receiver, video, stats);
    final picture = known == null || best == null
        ? known
        : _pictureRefusal(best, video, stats);
    final tentative = known != null && picture == null;
    final row = best ?? receiver;

    CastCompatibility ready(String contentType) =>
        CastReady(contentType: contentType, video: video, tentative: tentative);
    CastCompatibility rendition({required bool convertsSound}) => CastRendition(
      convertsSound: convertsSound,
      video: video,
      tentative: tentative,
    );

    if (readers.any(_matroskaReaders.contains)) {
      // A Matroska file carrying what a WebM carries is a WebM to a
      // receiver: the same container, the codecs it takes from one.
      final webm =
          _webmVideo.contains(video) &&
          (audio == null || _webm.audio.contains(audio));
      if (webm && picture == null) return ready(_webm.contentType);
      if (repackages && _repackagedVideo.contains(video)) {
        return picture ??
            rendition(convertsSound: _convertsSound(audio, surround));
      }
      if (repackages) return _renditionRefusal(row, video);
      if (webm) return picture!;
      return const CastRefused._container('a Matroska (.mkv) file');
    }
    if (!readers.any(_mp4Readers.contains)) {
      return CastRefused._container(_describeReader(readers.first));
    }

    if (picture != null) return picture;
    if (audio != null && !_mp4.audio.contains(audio)) {
      // An MP4 whose sound the receiver will not take (or will play
      // silent): the same picture, the sound converted.
      if (repackages && _repackagedVideo.contains(video)) {
        return rendition(convertsSound: true);
      }
      return CastRefused._audio(audio, _describeAudioSupport(_mp4));
    }
    // AAC the receiver takes, but in more than two channels: zond's
    // television sends its sound over Bluetooth, and multichannel AAC is not
    // known to play there, so it is mixed down as any other sound would
    // be. Where no rendition can be made it goes as it is, AAC being a
    // sound the receiver decodes.
    if (surround && repackages && _repackagedVideo.contains(video)) {
      return rendition(convertsSound: true);
    }
    return ready(_mp4.contentType);
  }

  /// Whether the stream can be cast as it is.
  bool get isReady => this is CastReady;
}

/// The stream can go to a receiver untouched.
final class CastReady extends CastCompatibility {
  const CastReady({
    required this.contentType,
    this.video,
    this.tentative = false,
  });

  /// The MIME type to tell the receiver, e.g. `video/mp4`.
  final String contentType;

  /// The picture's codec as judged (`HEVC`), or null for sound alone.
  final String? video;

  /// The receiver is not known to decode the picture, only that some model
  /// announcing its name does: a trial the player watches.
  final bool tentative;
}

/// The stream goes to a receiver as a rendition: the same H.264 or HEVC,
/// repackaged by the server into one fragmented MP4 the receiver plays as a
/// file (`MediaIds.publishRendition`), its sound copied when it is stereo
/// (or mono) AAC and converted to stereo AAC when [convertsSound].
final class CastRendition extends CastCompatibility {
  const CastRendition({
    this.convertsSound = false,
    this.video,
    this.tentative = false,
  });

  /// The picture's codec as judged (`H.264` or `HEVC`).
  final String? video;

  /// As [CastReady.tentative].
  final bool tentative;

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

  const CastRefused._pending()
    : this._(
        CastRefusal.pending,
        'The player has not said yet what kind of file this is, and that is '
        'what decides whether a Chromecast can play it. Try again once it '
        'has started playing.',
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

  const CastRefused._video(String subject, String supported, String codec)
    : this._(
        CastRefusal.videoCodec,
        '$subject plays $supported video; this film\'s video is $codec. '
        'Casting it would need conversion, which this app cannot do yet.',
      );

  const CastRefused._pictureSize(String subject, String limit, String film)
    : this._(
        CastRefusal.pictureSize,
        '$subject plays $limit; this film\'s picture is $film. xtremio sends '
        'the picture as it is, so this receiver cannot show it.',
      );

  const CastRefused._audio(String codec, String supported)
    : this._(
        CastRefusal.audioCodec,
        'A Chromecast decodes $supported; this stream is $codec. Casting it '
        'would need conversion, which this app cannot do yet.',
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

/// Why a stream was refused. [container] and [audioCodec] are about a file
/// the receiver would be handed as it is; [videoCodec] and [pictureSize]
/// about a picture the receiver does not decode, or not that big or that
/// fast, whether handed as it is or copied into a rendition;
/// [renditionVideo]
/// about one that would be repackaged but whose picture a copy cannot carry
/// (what a transcode, step F4 of the renditions design, would answer); a
/// rendition's sound is never refused here, since it is converted when it
/// is not AAC; [proxied] is never castable, and [pending] is not an answer
/// yet -- ask again when mpv has reported what the file is.
enum CastRefusal {
  proxied,
  pending,
  container,
  videoCodec,
  pictureSize,
  audioCodec,
  renditionVideo,
}

/// What a receiver plays, by container: the MIME type to declare, how a
/// sentence names the file, and the audio it may carry.
///
/// The audio hangs off the container because that is where the receiver
/// draws the line -- an MP3 track plays out of an MP4 and not out of a
/// WebM, and Opus the other way round -- so one flat list of codecs was
/// wrong whichever codecs it held.
typedef _Castable = ({String contentType, String name, Set<String> audio});

const _Castable _mp4 = (
  contentType: 'video/mp4',
  name: 'an MP4 file',
  audio: {'AAC', 'MP3'},
);
const _Castable _webm = (
  contentType: 'video/webm',
  name: 'a WebM file',
  audio: {'Opus', 'Vorbis'},
);

/// mpv's names (`file-format`) for the readers that open the MP4 family --
/// libavformat's one reader for MP4, M4V and QuickTime, which mpv names
/// `mov,mp4,m4a,3gp,3g2,mj2` -- and the Matroska family: mpv's own reader
/// (`mkv`) and libavformat's (`matroska,webm`). A name is matched as one
/// of the comma-separated parts, as libavformat writes them (lower case),
/// so one part per reader is enough.
const Set<String> _mp4Readers = {'mp4'};
const Set<String> _matroskaReaders = {'mkv', 'matroska'};

/// The video a WebM carries; with [_webm]'s audio, what makes a file of the
/// Matroska family one a receiver takes as it is.
const Set<String> _webmVideo = {'VP8', 'VP9'};

/// Readers of mpv's whose files a receiver will not take, so the sentence
/// can name the format instead of the reader.
const Map<String, String> _knownReaders = {
  'avi': 'an AVI file',
  'mpegts': 'an MPEG transport stream',
  'mpeg': 'an MPEG program stream',
  'asf': 'a Windows Media file',
  'flv': 'a Flash video file',
  'ogg': 'an Ogg file',
  'rm': 'a RealMedia file',
};

/// The video a rendition copies: what the producer and the server's muxer
/// carry (`avc1`, `hvc1`). Whether the receiver decodes it is its row's
/// to say ([ReceiverRow]). Dolby Vision is not visible from here: mpv reports it as HEVC, and the
/// libmpv this app ships (v0.36.0-549, media_kit's
/// libmpv-android-video-build v1.1.11) has no `dolby-vision-profile`
/// track property to ask. The producer reads the container's record,
/// copies profiles 7 and 8 as their base layer and refuses profile 5 with
/// its own sentence, which reaches the viewer through the readiness the
/// player polls while it prepares the cast.
const Set<String> _repackagedVideo = {'H.264', 'HEVC'};

/// The sound a rendition copies, in one or two channels
/// ([PlaybackStats.audioChannels]). Anything else is converted to stereo
/// AAC (step F3), AAC with more than two channels included. AAC whose
/// channels mpv has not reported is copied, as it was before mpv was asked:
/// a count nobody knows is not a reason to convert.
const String _repackagedAudio = 'AAC';

/// Whether a rendition's sound is converted: anything but AAC in one or two
/// channels ([surround]: more than two). A film with no sound track has
/// nothing to convert.
bool _convertsSound(String? audio, bool surround) =>
    audio != null && (audio != _repackagedAudio || surround);

/// A file of sound alone: an MP4 (an M4A) with AAC or MP3, or a WebM with
/// Opus or Vorbis, goes as it is; nothing else does, there being no picture
/// to make a rendition of.
CastCompatibility _soundAlone(List<String> readers, String audio) {
  final format = readers.any(_matroskaReaders.contains)
      ? _webm
      : readers.any(_mp4Readers.contains)
      ? _mp4
      : null;
  if (format == null) {
    return CastRefused._container(_describeReader(readers.first));
  }
  if (!format.audio.contains(audio)) {
    return CastRefused._audio(audio, _describeAudioSupport(format));
  }
  return CastReady(contentType: format.contentType);
}

/// A Matroska film played by id whose picture a copy cannot carry (VP8,
/// VP9, AV1, ...): a sentence that says whether the receiver could have
/// played it (a repackaging xtremio does not make yet) or not even that (a
/// conversion, step F4 of the renditions design).
CastRefused _renditionRefusal(ReceiverRow receiver, String video) =>
    CastRefused._rendition(
      CastRefusal.renditionVideo,
      receiver.decodes(video)
          ? "This film's video is $video, which xtremio can't repackage for "
                'casting yet.'
          : "This film's video is $video, which this receiver can't play, and "
                "xtremio can't convert it for casting yet.",
    );

/// What [receiver] makes of [video] at the size and rate mpv reports: null
/// when it shows it, else the refusal that says what it does play.
CastRefused? _pictureRefusal(
  ReceiverRow receiver,
  String video,
  PlaybackStats? stats,
) {
  if (!receiver.decodes(video)) {
    return CastRefused._video(receiver.subject, receiver.codecList, video);
  }
  final width = stats?.width;
  final height = stats?.height;
  final fps = stats?.containerFps;
  if (receiver.fits(video, width: width, height: height, fps: fps)) {
    return null;
  }
  final size = width == null || height == null ? null : '${width}x$height';
  final rate = fps == null ? null : '${fps.round()} frames a second';
  return CastRefused._pictureSize(
    receiver.subject,
    receiver.describeLimit(video),
    [?size, ?rate].join(' at '),
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

/// What a receiver takes out of [format], as the audio refusal says it:
/// "AAC or MP3 audio in an MP4 file".
String _describeAudioSupport(_Castable format) =>
    '${_orList(format.audio)} audio in ${format.name}';

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

/// What a file [reader] opened is, for a refusal that says what the file
/// is rather than repeating mpv's word for it.
String _describeReader(String reader) =>
    _knownReaders[reader] ?? 'a file of a kind mpv calls "$reader"';

/// The best name known for the file being played, first hit wins:
/// [serverFilename], then the converted stream's, then the selected
/// stream's `behaviorHints.filename`, then nothing. **Not read by the cast
/// check** -- mpv says what a file is -- but what the subtitle memory keys
/// a video release on.
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
