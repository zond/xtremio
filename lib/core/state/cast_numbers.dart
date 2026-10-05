/// What one published cast has served so far: stream-server's
/// `CastNumbers` (`ServerHandle::cast_numbers`, read over FFI as
/// `media_cast_numbers`), what the cast panel on the phone draws.
///
/// **Counts that only grow and positions as they are now, and no rate.**
/// The server keeps no clock for these; the panel takes two answers and
/// divides by the time between them. Every absence is null, never a zero,
/// and takes its row (or its half of one) away.
final class CastNumbers {
  const CastNumbers({
    required this.rendition,
    required this.delivery,
    required this.source,
    this.contentType,
    this.made,
  });

  /// Whether the receiver is sent the server's rendition
  /// (`/cast/<token>/stream.mp4`) rather than the source as it is.
  final bool rendition;

  /// What the receiver is answered with: the source's type for a plain
  /// publication once a request has resolved it, `video/mp4` for a
  /// rendition.
  final String? contentType;

  final CastDelivery delivery;
  final CastSource source;

  /// What the rendition has made; null for a plain publication.
  final RenditionMade? made;

  /// The JSON `media_cast_numbers` answers, or null for anything that is
  /// not one -- which draws the same as no answer: no server rows.
  static CastNumbers? fromJson(Object? value) {
    if (value is! Map) return null;
    final delivery = CastDelivery.fromJson(value['delivery']);
    final source = CastSource.fromJson(value['source']);
    if (delivery == null || source == null) return null;
    final contentType = value['contentType'];
    return CastNumbers(
      rendition: value['kind'] == 'rendition',
      contentType: contentType is String ? contentType : null,
      delivery: delivery,
      source: source,
      made: RenditionMade.fromJson(value['rendition']),
    );
  }
}

/// What the receiver has been sent under one token.
final class CastDelivery {
  const CastDelivery({
    required this.requests,
    required this.bodiesBegun,
    required this.bodiesOpen,
    required this.bytes,
    this.lastRequestAt,
    this.furthestAt,
  });

  /// Every `GET` and `HEAD` under the token, answered with bytes or not.
  /// A healthy receiver asks once per seek.
  final int requests;

  /// Responses that began a body, and those being read now.
  final int bodiesBegun;
  final int bodiesOpen;

  /// Bytes sent, over every body.
  final int bytes;

  /// The byte the latest body began at, and one past the furthest byte
  /// any body has sent.
  final int? lastRequestAt;
  final int? furthestAt;

  static CastDelivery? fromJson(Object? value) {
    if (value is! Map) return null;
    final requests = value['requests'];
    final begun = value['bodiesBegun'];
    final open = value['bodiesOpen'];
    final bytes = value['bytes'];
    if (requests is! int || begun is! int || open is! int || bytes is! int) {
      return null;
    }
    final last = value['lastRequestAt'];
    final furthest = value['furthestAt'];
    return CastDelivery(
      requests: requests,
      bodiesBegun: begun,
      bodiesOpen: open,
      bytes: bytes,
      lastRequestAt: last is int ? last : null,
      furthestAt: furthest is int ? furthest : null,
    );
  }
}

/// What was read from the source for the receiver.
final class CastSource {
  const CastSource({
    required this.bytesRead,
    required this.opens,
    required this.seeks,
    this.kind,
  });

  /// `torrent`, `member` (a file inside an archive) or `http` (a link, a
  /// Drive file, a file on this device); null before the first open.
  final String? kind;

  final int bytesRead;

  /// Opens (a body each for a plain cast, a run each for a rendition) and
  /// reopens at another offset inside one.
  final int opens;
  final int seeks;

  static CastSource? fromJson(Object? value) {
    if (value is! Map) return null;
    final read = value['bytesRead'];
    final opens = value['opens'];
    final seeks = value['seeks'];
    if (read is! int || opens is! int || seeks is! int) return null;
    final kind = value['kind'];
    return CastSource(
      kind: kind is String ? kind : null,
      bytesRead: read,
      opens: opens,
      seeks: seeks,
    );
  }
}

/// What a rendition has made, and where.
final class RenditionMade {
  const RenditionMade({
    required this.runs,
    required this.runsStarted,
    required this.slotsMade,
    required this.filmMade,
    this.videoCopied,
    this.videoCodec,
    this.soundConverted,
    this.soundCodec,
    this.soundChannels,
    this.soundBitrate,
    this.slots,
    this.slotLength,
    this.exact,
    this.madeTo,
  });

  /// Whether the picture is the film's own samples, repackaged; and the
  /// codec the first run reported making.
  final bool? videoCopied;
  final String? videoCodec;

  /// Whether the sound is converted; what it is made as.
  final bool? soundConverted;
  final String? soundCodec;
  final int? soundChannels;

  /// The bitrate converted sound is made at, bits per second.
  final int? soundBitrate;

  /// The layout, once the first run fixed it: how many slots, how long each
  /// is when they are all one length, and whether it mirrors the source's
  /// index (or is estimated).
  final int? slots;
  final Duration? slotLength;
  final bool? exact;

  final List<RenditionRun> runs;
  final int runsStarted;

  /// Every slot made since the publish, and the film they hold: two
  /// answers' difference over the time between them is the speed.
  final int slotsMade;
  final Duration filmMade;

  /// Where on the film's clock the unbroken run of made slots from the one
  /// the receiver last asked for ends: how far ahead it is made.
  final Duration? madeTo;

  static RenditionMade? fromJson(Object? value) {
    if (value is! Map) return null;
    final started = value['runsStarted'];
    final made = value['slotsMade'];
    final film = value['filmMadeMs'];
    if (started is! int || made is! int || film is! int) return null;
    final video = value['video'];
    final audio = value['audio'];
    final videoOut = value['videoOut'];
    final audioOut = value['audioOut'];
    final layout = value['layout'];
    final runs = value['runs'];
    final madeTo = value['madeToMs'];
    final converted = audio is Map ? audio['aacStereo'] : null;
    Object? field(Object? map, String key) => map is Map ? map[key] : null;
    final slotMs = field(layout, 'slotMs');
    final bitrate = field(converted, 'bitrate');
    final codec = field(videoOut, 'codec');
    final soundCodec = field(audioOut, 'codec');
    final channels = field(audioOut, 'channels');
    final slots = field(layout, 'slots');
    final exact = field(layout, 'exact');
    return RenditionMade(
      videoCopied: video == null ? null : video == 'copy',
      videoCodec: codec is String ? codec : null,
      soundConverted: audio == null ? null : audio != 'copy',
      soundCodec: soundCodec is String ? soundCodec : null,
      soundChannels: channels is int ? channels : null,
      soundBitrate: bitrate is int ? bitrate : null,
      slots: slots is int ? slots : null,
      slotLength: slotMs is int ? Duration(milliseconds: slotMs) : null,
      exact: exact is bool ? exact : null,
      runs: [
        if (runs is List)
          for (final run in runs) ?RenditionRun.fromJson(run),
      ],
      runsStarted: started,
      slotsMade: made,
      filmMade: Duration(milliseconds: film),
      madeTo: madeTo is int ? Duration(milliseconds: madeTo) : null,
    );
  }
}

/// A live run of a rendition: where on the film it began, and how many
/// slots it has made.
final class RenditionRun {
  const RenditionRun({required this.produced, this.from});

  final Duration? from;
  final int produced;

  static RenditionRun? fromJson(Object? value) {
    if (value is! Map) return null;
    final produced = value['produced'];
    if (produced is! int) return null;
    final from = value['fromMs'];
    return RenditionRun(
      from: from is int ? Duration(milliseconds: from) : null,
      produced: produced,
    );
  }
}
