import '../../core/core.dart';

/// What a stream says about itself, once the structured fields and the
/// free text have both been read: enough to put every addon's answers in
/// one order and to label a row with what is actually known.
///
/// **Nothing here is normative.** stremio-core models a stream as a source
/// plus a name, a description and `behaviorHints`; quality, size and
/// seeders are not fields of anything. So this reads, in order of how much
/// it can be trusted:
///
/// - **Structured**, and preferred wherever it exists:
///   `behaviorHints.videoSize` (bytes), `behaviorHints.filename`,
///   `behaviorHints.bingeGroup` (a release tag such as `pdm-1080p`), and
///   the source variant ([StreamInfo.kind]).
/// - **Text, but reliable**: the resolution and the source tags addons
///   write into the name and the filename (`1080p`, `WEB-DL`, `x265`), and
///   the size from the `💾 1.51 GB` convention when `videoSize` is absent
///   — that exact convention is in our own recorded fixture.
/// - **A guess, by convention only**: seeders, [languages], [audioTracks]
///   and [tracker]. No addon protocol carries any of them; torrent addons
///   write `👤 42 💾 35.09 GB ⚙️ RARBG` on one description line and the
///   flags on another. A parse that finds nothing is null (or empty),
///   never zero.
///
/// **`description` is where every addon writes, and none of them sets it.**
/// Not one row of `rust/tests/fixtures/addon_streams_recorded.json` has a
/// `description` key as it came off the wire: they all carry their text in
/// the legacy `title`, which stremio-core reads as `description` through a
/// serde alias (`types/resource/stream.rs`) and [StreamInfo.description]
/// reads the same way. So "the description" below always means "whatever
/// the addon wrote, whichever of the two keys it used", and a reader who
/// expects addons to populate `description` themselves will find none that
/// do.
///
/// Every field is nullable and nothing is ever defaulted: an absent value
/// means "not known", which is a different thing from "none" and sorts and
/// renders differently. A badge for an unknown is not drawn at all.
final class StreamFacts {
  const StreamFacts({
    this.resolution,
    this.sizeBytes,
    this.seeders,
    this.tags = const [],
    this.languages = const [],
    this.audioTracks,
    this.tracker,
    this.sourceKind,
    this.addonName,
    this.releaseTag,
    this.filename,
  });

  /// The video height, when one could be read.
  final StreamResolution? resolution;

  /// The file's size in bytes: `behaviorHints.videoSize` when the addon set
  /// it, else the `1.51 GB` written into the text. Never zero — an addon
  /// that says `videoSize: 0` is saying nothing.
  final int? sizeBytes;

  /// Seeders, when the description carried the convention. Null is
  /// "unknown", and is not the same as a swarm with nobody in it.
  final int? seeders;

  /// Source and codec tags, canonically spelled, in the fixed order of the
  /// table that recognises them (never the order they appeared in), so the
  /// same release always reads the same way.
  final List<String> tags;

  /// The flags an addon writes on a line of its own — `🇬🇧 / 🇷🇺 / 🇮🇹`
  /// (fixture row 2) — in the order it wrote them, and as it wrote them: a
  /// flag is what a pill draws, and the country it names is the only thing
  /// the addon actually said.
  ///
  /// Empty is "the addon said nothing about language", which is not
  /// "English" and not "one track". Nine of the twenty-five recorded rows
  /// carry this line and sixteen do not, so an empty list is the common
  /// case and must never be drawn as a claim.
  final List<String> languages;

  /// The phrase that leads the language line when there is one: `Multi
  /// Audio` (row 3), `Dual Audio` (row 8).
  ///
  /// Kept as its own fact because it is *not* derivable from [languages]:
  /// row 9 is `Multi Audio / 🇬🇧`, six English tracks under one flag, and
  /// row 16 is `Multi Audio / 🇫🇷`. Counting the flags would call both of
  /// those single-audio.
  final String? audioTracks;

  /// The site the torrent was indexed on, from the `⚙️ RARBG` field of the
  /// stats line (rows 1, 2, 3 — `RARBG`, `ThePirateBay`, `1337x`,
  /// `Rutracker`, `Torrent9`).
  ///
  /// **Not a BitTorrent tracker**, however it is spelled. The announce URLs
  /// are [StreamInfo.trackers], off the stream's own `announce` / `sources`
  /// array (row 13 carries twenty-six of them, row 25 an empty one, and
  /// most rows none at all). This is a search index's name, with nothing to
  /// announce to; it is worth showing because it is the only thing a
  /// listing says about where it came from, and worth never handing to the
  /// streaming server.
  final String? tracker;

  /// The `StreamSource` variant, or null for [StreamKind.unknown] — the
  /// engine could not tell either.
  final StreamKind? sourceKind;

  /// The addon that answered with this stream, as the row should name it.
  final String? addonName;

  /// `behaviorHints.bingeGroup`: the addon's own tag for "the same release
  /// as", e.g. `pdm-1080p`. Read for a resolution when nothing else has
  /// one, and kept because it is the closest thing to a release id.
  final String? releaseTag;

  /// `behaviorHints.filename`, when the addon set it.
  final String? filename;

  /// Reads [stream]. [addonName] is the label the list should show, which
  /// the stream itself never carries — it comes from the profile, or from
  /// the host of the manifest URL it was asked at.
  factory StreamFacts.of(StreamInfo stream, {String? addonName}) {
    final hints = stream.behaviorHints;
    final releaseTag = hints['bingeGroup'] as String?;
    final filename = stream.filename;
    final name = stream.name;
    final description = stream.description;
    // Most trusted first: the name and the filename are where a release is
    // described, the binge group is the addon's own release tag, and the
    // description is free text that happens to often repeat both.
    final ranked = [?name, ?filename, ?releaseTag, ?description];
    final all = ranked.join('\n');
    final spoken = _parseLanguages(description);
    return StreamFacts(
      resolution: _firstResolution(ranked),
      sizeBytes: _videoSize(hints['videoSize']) ?? _parseSize(all),
      seeders: _parseSeeders(all),
      tags: _parseTags(all),
      languages: spoken.flags,
      audioTracks: spoken.audio,
      tracker: _parseTracker(all),
      sourceKind: stream.kind == StreamKind.unknown ? null : stream.kind,
      addonName: addonName,
      releaseTag: releaseTag,
      filename: filename,
    );
  }

  /// The pills a card draws, in display order, with an unknown omitted
  /// entirely rather than shown as a placeholder.
  ///
  /// **These are the parse, drawn beside the text it was read out of.** A
  /// card carries the addon's own lines whole ([StreamPresentation]), so a
  /// `💾 4.98 GB` in that text and a `4.98 GB` pill next to it say the same
  /// thing twice on purpose: the repetition is how a viewer sees the
  /// reading agree with what was written -- or catch it not agreeing. The
  /// values a sort and a section are built out of are in this list, so
  /// "why is this row here" is answered on the row.
  ///
  /// [languages] is **one** pill holding every flag, not a pill each. A
  /// pill each was drawn and measured first: recorded row 2 carries
  /// seventeen flags, which is seventeen boxes wrapping to six rows on a
  /// 260 dp television card -- 130 dp of pills over two lines of text, and
  /// the flags are the one thing on the card that is already legible as a
  /// run. [audioTracks] is deliberately not here: `Multi Audio` is a claim
  /// about a file rather than a value anything sorts by, and it is already
  /// on the card in the line it was read from.
  List<String> get pills => [
    ?resolutionLabel,
    ?sizeLabel,
    ?seedersLabel,
    ?languagesLabel,
    ?tracker,
  ];

  /// Every flag the addon wrote, in its order, as one pill's worth of
  /// text; null when it wrote none, which is not "English".
  String? get languagesLabel => languages.isEmpty ? null : languages.join(' ');

  String? get resolutionLabel => resolution?.label;

  /// `1.51 GB`, in the same 1024-based units the addons' own text uses.
  String? get sizeLabel => formatSize(sizeBytes);

  String? get seedersLabel => switch (seeders) {
    null => null,
    1 => '1 seeder',
    final count => '$count seeders',
  };

  /// [bytes] as `1.51 GB`; null for null. Binary units, matching what the
  /// `💾` convention is computed with.
  static String? formatSize(int? bytes) {
    if (bytes == null) return null;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    // Whole bytes and kilobytes have no meaningful fraction to show, and a
    // fraction that is all zeros is noise: `20 GB`, not `20.00 GB`.
    final digits = unit <= 1 ? 0 : (value >= 100 ? 0 : 2);
    var text = value.toStringAsFixed(digits);
    if (text.contains('.')) {
      text = text
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
    }
    return '$text ${units[unit]}';
  }

  /// The first resolution any of [sources] yields, in their order.
  static StreamResolution? _firstResolution(List<String> sources) {
    for (final source in sources) {
      final found = _resolutionIn(source);
      if (found != null) return found;
    }
    return null;
  }

  static StreamResolution? _resolutionIn(String text) {
    final token = _resolutionPattern.firstMatch(text);
    if (token != null) {
      return _resolutionTokens[token.group(1)!.toLowerCase()];
    }
    // `1920x1080`, which filenames from a ripper often carry instead.
    final dimensions = _dimensionsPattern.firstMatch(text);
    final height = dimensions == null
        ? null
        : int.tryParse(dimensions.group(2)!);
    return height == null ? null : StreamResolution.forHeight(height);
  }

  /// `behaviorHints.videoSize`, when it is a positive count of bytes. Zero
  /// is not a size; an addon that sends it is saying nothing.
  static int? _videoSize(Object? value) {
    final bytes = switch (value) {
      final int bytes => bytes,
      final double bytes => bytes.round(),
      final String bytes => int.tryParse(bytes),
      _ => null,
    };
    return bytes != null && bytes > 0 ? bytes : null;
  }

  static int? _parseSize(String text) {
    final match = _sizePattern.firstMatch(text);
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!.replaceAll(',', '.'));
    if (value == null) return null;
    final multiplier = _sizeUnits[match.group(2)!.toLowerCase()[0]]!;
    return (value * multiplier).round();
  }

  static int? _parseSeeders(String text) {
    for (final pattern in _seederPatterns) {
      final match = pattern.firstMatch(text);
      if (match != null) return int.tryParse(match.group(1)!);
    }
    return null;
  }

  static List<String> _parseTags(String text) => [
    for (final MapEntry(key: label, value: pattern) in _tagPatterns.entries)
      if (pattern.hasMatch(text)) label,
  ];

  /// The language line of [description], read for what is on it.
  ///
  /// Found by **what it contains, not where it is**: it is line 3 on
  /// fixture row 2 and line 4 on row 7, and on the rows with no filename
  /// line it moves up again. The one thing true of every one of them is a
  /// flag, and no other line in any recorded row has one — the release
  /// lines, the file lines and the `👤 … 💾 … ⚙️ …` stats lines are all
  /// flagless. So the flag is the marker.
  ///
  /// Split on `/`, which is what the addon joined them with. An item that
  /// is a flag and nothing else is a language; the one item that is not is
  /// the audio phrase that leads the line (`Multi Audio`, `Dual Audio`).
  /// Only the first such item is taken: no recorded row has two, and a row
  /// that did would be saying something this does not yet understand.
  static ({List<String> flags, String? audio}) _parseLanguages(
    String? description,
  ) {
    for (final line in (description ?? '').split('\n')) {
      if (!_flagPattern.hasMatch(line)) continue;
      final flags = <String>[];
      String? audio;
      for (final part in line.split('/')) {
        final item = part.trim();
        if (item.isEmpty) continue;
        if (_flagOnlyPattern.hasMatch(item)) {
          flags.add(item);
        } else {
          audio ??= item;
        }
      }
      return (flags: flags, audio: audio);
    }
    return (flags: const <String>[], audio: null);
  }

  /// The indexer after the `⚙️` on the stats line, to the end of that line.
  ///
  /// To the end of the line and not to the next space: every recorded name
  /// happens to be one token (`RARBG`, `ThePirateBay`, `1337x`,
  /// `Rutracker`, `Torrent9`) and `⚙️` is the last field Torrentio writes,
  /// so a site whose name has a space in it survives whole rather than
  /// arriving as its first word.
  static String? _parseTracker(String text) {
    final name = _trackerPattern.firstMatch(text)?.group(1)?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  static final RegExp _resolutionPattern = RegExp(
    r'\b(2160p|4k|uhd|1440p|1080p|720p|576p|480p|360p|240p)\b',
    caseSensitive: false,
  );

  static const Map<String, StreamResolution> _resolutionTokens = {
    '2160p': StreamResolution.uhd2160,
    '4k': StreamResolution.uhd2160,
    'uhd': StreamResolution.uhd2160,
    '1440p': StreamResolution.qhd1440,
    '1080p': StreamResolution.fhd1080,
    '720p': StreamResolution.hd720,
    '576p': StreamResolution.sd576,
    '480p': StreamResolution.sd480,
    '360p': StreamResolution.sd360,
    '240p': StreamResolution.sd240,
  };

  static final RegExp _dimensionsPattern = RegExp(
    r'\b(\d{3,4})\s?[x×]\s?(\d{3,4})\b',
    caseSensitive: false,
  );

  /// `1.51 GB`, `700MB`, `1,4 GiB`. A bare `B` is not a unit here: no video
  /// is measured in bytes, and the number before it is usually something
  /// else entirely.
  static final RegExp _sizePattern = RegExp(
    r'(?<![\w.])(\d+(?:[.,]\d+)?)\s?([KMGT])i?B\b',
    caseSensitive: false,
  );

  static const Map<String, int> _sizeUnits = {
    'k': 1024,
    'm': 1024 * 1024,
    'g': 1024 * 1024 * 1024,
    't': 1024 * 1024 * 1024 * 1024,
  };

  /// The `👤 42` convention first, then the two ways an addon spells it out.
  static final List<RegExp> _seederPatterns = [
    RegExp(r'👤\s?(\d+)'),
    RegExp(r'\bseeder?s?\s*[:=]\s*(\d+)', caseSensitive: false),
    RegExp(r'\b(\d+)\s?seeders?\b', caseSensitive: false),
  ];

  /// A flag: two regional indicator symbols, which is how every addon in
  /// the recorded fixture writes a language.
  ///
  /// `unicode: true` for the reason [StreamHints.strip] spells out at
  /// length: these are astral code points, and without the flag a Dart
  /// character class matches UTF-16 *code units* — the halves of a flag,
  /// not the flag — which is how an emoji ends up cut in two and drawn as
  /// a replacement character.
  static final RegExp _flagPattern = RegExp(
    r'[\u{1F1E6}-\u{1F1FF}]{2}',
    unicode: true,
  );

  /// A line item that is a flag and nothing else, so `Multi Audio` is told
  /// from `🇬🇧` without a list of the phrases an addon might lead with.
  static final RegExp _flagOnlyPattern = RegExp(
    r'^[\u{1F1E6}-\u{1F1FF}]{2}$',
    unicode: true,
  );

  /// `⚙️ RARBG`, to the end of its line. The variation selector is optional
  /// because it is a presentation hint an addon may or may not have sent;
  /// the gear itself is the field marker.
  static final RegExp _trackerPattern = RegExp('⚙️?[ \t]*([^\n]+)');

  /// Canonical label to what spells it. Iteration order is the display
  /// order of [tags], so the source comes before the dynamic range before
  /// the codec whatever order the addon wrote them in.
  static final Map<String, RegExp> _tagPatterns = {
    'REMUX': RegExp(r'\bremux\b', caseSensitive: false),
    'BluRay': RegExp(r'\bblu-?ray\b|\bbdremux\b', caseSensitive: false),
    'BDRip': RegExp(r'\b(?:bd|br)rip\b', caseSensitive: false),
    'WEB-DL': RegExp(r'\bweb-?dl\b', caseSensitive: false),
    'WEBRip': RegExp(r'\bweb-?rip\b', caseSensitive: false),
    'HDTV': RegExp(r'\bhdtv\b', caseSensitive: false),
    'DVDRip': RegExp(r'\bdvd-?rip\b', caseSensitive: false),
    'CAM': RegExp(r'\bcam(?:rip)?\b', caseSensitive: false),
    'HDR': RegExp(r'\bhdr(?:10)?\+?\b', caseSensitive: false),
    'DV': RegExp(r'\bdolby[ .]?vision\b|\bdo?vi?\b', caseSensitive: false),
    'HEVC': RegExp(r'\bx265\b|\bh\.?265\b|\bhevc\b', caseSensitive: false),
    'AVC': RegExp(r'\bx264\b|\bh\.?264\b|\bavc\b', caseSensitive: false),
    'AV1': RegExp(r'\bav1\b', caseSensitive: false),
    '10bit': RegExp(r'\b10-?bits?\b', caseSensitive: false),
    'Atmos': RegExp(r'\batmos\b', caseSensitive: false),
    'DTS': RegExp(r'\bdts(?:-?hd)?\b', caseSensitive: false),
    'PROPER': RegExp(r'\bproper\b', caseSensitive: false),
  };
}

/// A video height, as the ladder a sort walks down. The label is the way
/// the height is usually written, so a badge reads like the release does.
enum StreamResolution {
  uhd2160(2160, '2160p'),
  qhd1440(1440, '1440p'),
  fhd1080(1080, '1080p'),
  hd720(720, '720p'),
  sd576(576, '576p'),
  sd480(480, '480p'),
  sd360(360, '360p'),
  sd240(240, '240p');

  const StreamResolution(this.height, this.label);

  /// Pixels, and the only thing the comparator looks at.
  final int height;

  final String label;

  /// The rung [height] belongs to: the highest one it reaches. `1088`
  /// (a mod-16 1080p encode) is 1080p; anything below the bottom rung is
  /// null rather than pinned to it.
  static StreamResolution? forHeight(int height) {
    for (final resolution in values) {
      if (height >= resolution.height) return resolution;
    }
    return null;
  }
}

/// The order the streams *inside* one resolution section are in.
///
/// Resolution is not part of this at all: it is what the sections
/// themselves are (see [sectionsByResolution]), so a comparison here is
/// always between two streams of the same picture.
///
/// The rule every one of the three shares is what it does with an unknown.
/// A stream whose size, or whose peer count, was nowhere to be read cannot
/// be ranked by an order that needs it, and the honest place for it is
/// *after* everything that could be ranked — never as a zero (which would
/// pin it to the bottom of the ranking as if it were measured and found
/// empty) and never as a best guess (which would put it on top of streams
/// that are actually known to be good). Two unranked streams compare equal,
/// so they keep the order the addons gave them.
///
/// Ties fall through the same way: two streams the order cannot tell apart
/// stay as they came in, which is the addon's own ranking (see
/// [sortedByStreamOrder]).
int compareStreamOrder(StreamFacts a, StreamFacts b, StreamOrder order) =>
    switch (order) {
      StreamOrder.peersPerSize => _byPeersPerSize(a, b),
      StreamOrder.largest => _byKnown(a.sizeBytes, b.sizeBytes),
      StreamOrder.mostPeers => _byKnown(a.seeders, b.seeders),
    };

/// Ascending size ÷ peers — the most peers per megabyte first — for the
/// reasoning in [StreamOrder].
///
/// The ratio is taken in doubles rather than by cross-multiplying, because
/// a size in bytes times a peer count read off arbitrary text is a product
/// that can leave 64 bits, and a comparator that wraps around is a
/// comparator that crashes a sort. It also gives the swarm with nobody in
/// it the right answer for free: size ÷ 0 is infinity, the worst ratio
/// there is, so a stream *known* to have no peers ranks last among the
/// ranked instead of being thrown in with the unknowns.
int _byPeersPerSize(StreamFacts a, StreamFacts b) {
  final ratioA = _peersPerSize(a);
  final ratioB = _peersPerSize(b);
  if (ratioA == null && ratioB == null) return 0;
  if (ratioA == null) return 1;
  if (ratioB == null) return -1;
  return ratioA.compareTo(ratioB);
}

/// Bytes per peer, or null when either half is unknown. `double.compareTo`
/// is a total order (it even orders a NaN, which only a zero-byte stream
/// with no peers could produce), so a sort over these cannot come apart.
double? _peersPerSize(StreamFacts facts) {
  final size = facts.sizeBytes;
  final peers = facts.seeders;
  return size == null || peers == null ? null : size / peers;
}

/// Larger first, with "unknown" as a bucket of its own *after* every known
/// value.
int _byKnown(int? a, int? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}

/// [items] in [compareStreamOrder] order, **stably**: two streams that
/// compare equal come out in the order they went in, so what the addon
/// itself ranked first still shows through.
///
/// Stability has to be built here because `List.sort` does not promise it.
/// [facts] is called once per item.
List<T> sortedByStreamOrder<T>(
  List<T> items,
  StreamFacts Function(T item) facts,
  StreamOrder order,
) {
  final decorated = [
    for (final (index, item) in items.indexed) (index, item, facts(item)),
  ];
  decorated.sort((a, b) {
    final byOrder = compareStreamOrder(a.$3, b.$3, order);
    return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
  });
  return [for (final entry in decorated) entry.$2];
}

/// One resolution's worth of the sources list: the rows themselves, and the
/// two things a *collapsed* header still has to be able to say — how many
/// streams are folded away in it, and the best swarm among them, so an
/// empty-looking 2160p is told apart from a healthy one without opening it.
final class StreamSection<T> {
  const StreamSection({
    required this.resolution,
    required this.rows,
    required this.bestSeeders,
  });

  /// The rung, or null for the streams nothing could be read from. Null is
  /// never a guess at a resolution and is never drawn as one.
  final StreamResolution? resolution;

  final List<T> rows;

  /// The most peers any stream in the section claims, or null when not one
  /// of them said. Null is "nobody said", not "nobody is there".
  final int? bestSeeders;

  /// The heading, which for the unknown bucket says so rather than
  /// guessing.
  String get label => resolution?.label ?? 'Unknown resolution';

  /// What a collapsed header says about what it holds.
  String get summary => [
    rows.length == 1 ? '1 stream' : '${rows.length} streams',
    switch (bestSeeders) {
      null => 'seeders unknown',
      1 => 'best 1 seeder',
      final best => 'best $best seeders',
    },
  ].join(' · ');
}

/// [rows] split into one section per resolution, **highest first**, with
/// the streams nothing could be read a resolution from last as a section of
/// their own.
///
/// The order *within* a section is the order [rows] came in, so a list
/// already put in [sortedByStreamOrder] order arrives sectioned and sorted
/// in one pass. A resolution no stream has is not an empty section: it is
/// not there at all.
List<StreamSection<T>> sectionsByResolution<T>(
  List<T> rows,
  StreamFacts Function(T row) facts,
) {
  final buckets = <StreamResolution?, List<T>>{};
  final best = <StreamResolution?, int>{};
  for (final row in rows) {
    final rowFacts = facts(row);
    (buckets[rowFacts.resolution] ??= []).add(row);
    final seeders = rowFacts.seeders;
    if (seeders != null) {
      final known = best[rowFacts.resolution];
      if (known == null || seeders > known) {
        best[rowFacts.resolution] = seeders;
      }
    }
  }
  return [
    // `StreamResolution.values` is the ladder, highest rung first; the
    // unknown bucket is appended after it rather than sorted into it.
    for (final resolution in [...StreamResolution.values, null])
      if (buckets[resolution] case final rows?)
        StreamSection(
          resolution: resolution,
          rows: rows,
          bestSeeders: best[resolution],
        ),
  ];
}

/// What a card says about one stream, in the two registers a card has: the
/// [lead] line that names the thing a press would start, and the [rest] of
/// what the addon said under it.
///
/// It is a pair and not one string because addons answer in two registers
/// too. Torrentio's `title` is a little document — a release, sometimes a
/// file under it, a stats line, sometimes a line of flags — and the app has
/// been picking one line out of it and throwing the document away. Both
/// halves come from the same read of the same fields, so the lead can never
/// be a line the rest also shows.
///
/// **This is values, not layout.** Where the two go on a card, how many
/// lines each gets, whether the rest is folded away — none of that is
/// settled here.
final class StreamPresentation {
  const StreamPresentation({required this.lead, required this.rest});

  /// The one line that names what would play. Never empty: see [leadLineOf].
  final String lead;

  /// The addon's own text, line by line, in the order it wrote it, with
  /// what [lead] already said taken out of it — and nothing else taken out.
  /// Empty when the addon said nothing beyond the lead.
  ///
  /// **Taken out, not matched out.** A line that *is* the lead goes, as it
  /// always did: on fixture row 4 the lead comes from
  /// `behaviorHints.filename` and the second text line is that same file
  /// with `.mkv` on it, and on row 12 it is that same file with a directory
  /// in front of it — neither is a string match for the lead, and both are
  /// the lead ([_asLeadKey]). A line that names the same release *spelled
  /// more fully* is reduced to the part the lead has not already said
  /// ([_beyondTheLead]): row 1 sends the release twice, once as
  /// `…UHD.BluRay.X265-IAMABLE` and once as
  /// `…UHD.BluRay.x265.10bit.HDR.TrueHD.7.1.Atmos-IAMABLE`, and what the
  /// second one is actually for is `10bit.HDR.TrueHD.7.1.Atmos`.
  ///
  /// Everything else is untouched, whole, in the addon's own words.
  final List<String> rest;

  /// Reads [stream]. [addonName] is the label the card shows elsewhere; see
  /// [leadLineOf] for what it is used for.
  factory StreamPresentation.of(StreamInfo stream, {String? addonName}) {
    final lead = leadLineOf(stream, addonName: addonName);
    return StreamPresentation(
      lead: lead,
      rest: [
        for (final line in (stream.description ?? '').split('\n'))
          if (line.trim() case final text when text.isNotEmpty)
            ?_beyondTheLead(text, lead),
      ],
    );
  }
}

/// The one line a card leads with — `Avalon.2001.1080p.BluRay.x264-CiNEFiLE`
/// — chosen by **which fields this stream actually has**.
///
/// The engine models a stream as a source plus a `name`, a `description`
/// and `behaviorHints`, and *none* of them is "the release". So the branch
/// is on what is there, most trustworthy first, and every branch below
/// names the row of `rust/tests/fixtures/addon_streams_recorded.json` that
/// is the evidence for it.
///
/// 1. **`behaviorHints.filename` is set** → that, minus its container
///    extension (a card is not a directory listing).
///
///    This is the branch the packs need. Row 4 leads its text with
///    `[PACK] The Matrix 4K UHD Collection (1999-2003) …` and puts
///    `The Matrix (1999) (2160p HDR BDRip x265 10bit DTS) [4KLiGHT].mkv`
///    on the line below it — so line one names a **collection** and only
///    the filename names the film. Nine of the sixteen recorded Torrentio
///    rows are that shape: a pack (4), a trilogy (9), a season (10, 11, 12,
///    13, 16), a complete series, and an `Imdb top 263 movies hindi english
///    gdrive` dump (7, 8) where line one is not even a title. Heading any
///    of them with line one names something a press would not start.
///
/// 2. **No filename, but the first description line looks like a release**
///    → that line, with the `💾`/`👤` markers and their numbers taken off
///    ([StreamHints.strip]) so a size does not land in the headline that
///    the badges repeat.
///
///    Row 3 is the only recorded stream in this branch: no
///    `behaviorHints.filename` at all, and `The Matrix 1999 UHD Blu-ray
///    2160p HDR Remux Multi Atmos 7.1-DTOne` on line one. "Looks like a
///    release" ([_looksLikeARelease]) is what keeps prose out — see 3.
///
/// 3. **Otherwise `name`**, on one line.
///
///    This is every WatchHub row (17, 18, 20–24) and both Public Domain
///    Movies rows (19, 25). WatchHub's text is an availability phrase —
///    `Subscription`, `Rent, Buy`, `ADS`, `Subscription, Rent, Buy` — never
///    a release and never a closed set, and its `name` is the service:
///    `Amazon Prime Video`, `Plex`, `MUBI`. Public Domain Movies writes
///    `💾 1.51 GB`, which strips to nothing at all, and names the stream
///    `1080p`. Leading with the text would head those cards `Subscription`
///    and blank.
///
/// 4. **Nothing usable anywhere** → what kind of source it is, which is
///    what the list showed for such a stream before any of this existed.
///
/// [addonName] is what the card says elsewhere, and a candidate equal to it
/// is skipped rather than drawn: an addon whose description is its own name
/// would otherwise have the card say that name twice, once as the release
/// it does not have and once as the addon that answered.
///
/// Never empty.
String leadLineOf(StreamInfo stream, {String? addonName}) {
  final hints = StreamHints.of(stream);
  final described = hints.strip(_firstLine(stream.description));
  final candidates = [
    _withoutExtension(stream.filename),
    described != null && _looksLikeARelease(described) ? described : null,
    _oneLine(stream.name),
  ];
  for (final candidate in candidates) {
    final release = candidate?.trim();
    if (release == null || release.isEmpty) continue;
    if (addonName != null && release.toLowerCase() == addonName.toLowerCase()) {
      continue;
    }
    return release;
  }
  return _oneLine(stream.name) ??
      _oneLine(stream.description) ??
      stream.kind.label;
}

/// [leadLineOf] under the name the screens have always called it. Kept
/// because four call sites read it and a card's headline *is* the release
/// wherever an addon named one; [leadLineOf] is the honest name for what it
/// returns on the rows where no addon did.
String releaseNameOf(StreamInfo stream, {String? addonName}) =>
    leadLineOf(stream, addonName: addonName);

/// [line] reduced to what makes two spellings of one file the same file, so
/// a card does not draw its own headline again underneath itself.
///
/// Three reductions, each with a recorded row behind it:
///
/// - **the last path segment**, because row 12's file line is
///   `Breaking.Bad.S01…-TrollUHD/Breaking.Bad.S01E01…-TrollUHD.mkv` and
///   `behaviorHints.filename` is only the part after the slash;
/// - **without the container extension**, because that file line ends
///   `.mkv` and the filename the lead came from was stripped of it;
/// - **every run of `.`, `_`, `-` and space as one space, lower-cased**,
///   because row 5 writes the release with spaces on its text line and with
///   dots in its filename — `The Matrix 1999 UHD BluRay 2160p TrueHD Atmos
///   7 1 DV HEVC REMUX-FraMeSToR` against
///   `The.Matrix.1999.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.REMUX-FraMeSToR`
///   — and row 11 writes `Breaking Bad  S01E01  Pilot.mkv` with the double
///   spaces its filename also has.
///
/// It is deliberately blunt about separators and deliberately blind to
/// everything else: row 1's text line has `10bit.HDR.TrueHD.7.1.Atmos` in
/// it that its filename does not, so it is a different line and stays.
String _asLeadKey(String line) =>
    _asFile(line).toLowerCase().replaceAll(RegExp(r'[ ._-]+'), ' ').trim();

/// [line] as the file it names: its last path segment, without a container
/// extension. The two reductions [_asLeadKey] spells out, on their own,
/// because [_beyondTheLead] has to compare the same thing and then quote
/// from it.
String _asFile(String line) {
  final base = line.substring(line.lastIndexOf('/') + 1);
  return _withoutExtension(base) ?? base;
}

/// What [line] still has to say once [lead] has said its piece: the line
/// itself when it is not about the lead's release at all, what is left of
/// it when it is the same release spelled more fully, and null when nothing
/// of it is left.
///
/// **Why a line needs subtracting and not just dropping.** Torrentio
/// routinely sends the release twice, in two spellings, and the fuller of
/// the two is not the one the lead comes from: recorded row 1 leads with
/// `The.Matrix.1999.RERIP.2160p.UHD.BluRay.X265-IAMABLE` (the filename) and
/// writes `…UHD.BluRay.x265.10bit.HDR.TrueHD.7.1.Atmos-IAMABLE` on the line
/// under it. Eighty per cent of that line is the line above it; the fifth
/// that is not — `10bit HDR TrueHD 7.1 Atmos` — is the audio and the bit
/// depth, which are on the card nowhere else.
///
/// **What counts as the same release.** Two names say the same release when
/// they agree on the *identity head* ([_identityHead]): the title, the year
/// and the episode, which is everything before the first word about the
/// picture. It is not equality (the two spellings differ by definition) and
/// it is not a shared prefix (`The Matrix` is shared by a film and by the
/// box set it came in). It is the head *and only the head* because that is
/// exactly what a pack line changes: row 4 says `[PACK] The Matrix 4K UHD
/// Collection (1999-2003) …`, row 9 `The Matrix Trilogy (1999-2003) …`, row
/// 10 `S01` where the file says `S01E01`, row 12 `COMPLETE S01-S05`, row 16
/// `iNTEGRALE`. Every one of those shares most of its words with the lead
/// and names something else, and every one of them survives here whole,
/// because which pack a file came out of is worth knowing.
///
/// **And a second guard, for the lines nothing is known about.** More of
/// the line has to be the lead than is not. A line that merely shares a
/// word or two — a different release of the same film, say — is left alone:
/// the failure that matters is mangling a line, not repeating one.
///
/// What is subtracted is tokens, not characters ([_tokensOf]), because
/// addons separate with `.`, `_`, `-` and spaces interchangeably and wrap a
/// year in brackets as the mood takes them. A token the line has twice and
/// the lead has once is removed *once*: the lead said it once, and the
/// second one is the line saying something more. What comes back is the
/// addon's own text — its own spelling, its own separators — with the
/// removed words lifted out of it, never a normalised rewrite.
String? _beyondTheLead(String line, String lead) {
  // The line that simply is the lead again, which is the common case and
  // was the only case this handled before.
  if (_asLeadKey(line) == _asLeadKey(lead)) return null;
  final file = _asFile(line);
  final tokens = _tokensOf(file);
  final said = _tokensOf(lead);
  final head = _identityHead(tokens);
  // An empty head is a line with no title in it at all -- a stats line, a
  // line of flags, `Subscription` -- and two empty heads are not an
  // agreement about anything.
  if (head.isEmpty || !_sameTokens(head, _identityHead(said))) return line;
  final budget = <String, int>{};
  for (final token in said) {
    budget[token.text] = (budget[token.text] ?? 0) + 1;
  }
  final kept = <int>[];
  var removed = 0;
  for (final (index, token) in tokens.indexed) {
    final spoken = budget[token.text] ?? 0;
    if (spoken == 0) {
      kept.add(index);
    } else {
      budget[token.text] = spoken - 1;
      removed++;
    }
  }
  if (removed <= kept.length) return line;
  if (kept.isEmpty) return null;
  final remainder = StringBuffer();
  for (final (position, index) in kept.indexed) {
    // The separator the addon itself put in front of this word, so what is
    // left reads the way the line it came out of does. The one in front of
    // the first word separates it from nothing and stays behind with it.
    if (position > 0) {
      remainder.write(
        file.substring(tokens[index - 1].end, tokens[index].start),
      );
    }
    remainder.write(file.substring(tokens[index].start, tokens[index].end));
  }
  return remainder.toString();
}

/// One word of a release name, lower-cased, and where it sat in the line it
/// was read out of so the line can be quoted back.
typedef _Token = ({String text, int start, int end});

/// The words of [line]: its runs of letters and digits.
///
/// Everything else is a separator, because everything else is one somewhere
/// — the same release arrives as `The.Matrix.1999` from one addon,
/// `The Matrix (1999)` from the next and `The_Matrix_1999` from a third,
/// and a comparison that can be told apart by that is a comparison of
/// punctuation. Letters are taken by Unicode class and not by `[a-z]`:
/// recorded row 13's text line is Russian, and a tokeniser that dropped it
/// would have that line agreeing with anything.
List<_Token> _tokensOf(String line) => [
  for (final match in _tokenPattern.allMatches(line))
    (text: match[0]!.toLowerCase(), start: match.start, end: match.end),
];

final RegExp _tokenPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// The part of [tokens] that says *what* this is rather than what it looks
/// like: the title, its year and its episode.
///
/// Read as "everything up to the picture": a release name is a title, then
/// a resolution, then the tags, and the first resolution word is the most
/// reliable mark of where the title stopped in a string nobody agreed a
/// format for. Anything after the last year or season/episode inside that
/// head is dropped with it (`RERIP`, an edition, a scene word), so two
/// spellings that differ only in what edition they announce still agree on
/// what film they are.
///
/// Empty when there is no title before the first resolution — `1080p` is a
/// whole recorded stream name (row 19) — and an empty head is never an
/// agreement (see [_beyondTheLead]).
List<String> _identityHead(List<_Token> tokens) {
  var end = tokens.length;
  for (final (index, token) in tokens.indexed) {
    if (StreamFacts._resolutionTokens.containsKey(token.text)) {
      end = index;
      break;
    }
  }
  var last = -1;
  for (var index = 0; index < end; index++) {
    final text = tokens[index].text;
    if (_yearToken.hasMatch(text) || _episodeToken.hasMatch(text)) last = index;
  }
  return [
    for (final token in tokens.take(last >= 0 ? last + 1 : end)) token.text,
  ];
}

bool _sameTokens(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (final (index, token) in a.indexed) {
    if (token != b[index]) return false;
  }
  return true;
}

/// A year a film could have come out in, which is also the one number in a
/// release name that is part of what it is rather than how it looks.
final RegExp _yearToken = RegExp(r'^(?:19|20)\d{2}$');

/// `S01`, `S01E01`, `1x01` — the other half of what a release *is*, and the
/// one character between naming an episode and naming the season it came in
/// (recorded row 10).
final RegExp _episodeToken = RegExp(
  r'^(?:s\d{1,3}(?:e\d{1,4})?|\d{1,2}x\d{1,3})$',
);

/// Whether a line of free text is a release rather than a sentence about
/// the stream.
///
/// A release is built out of tokens joined by dots, underscores or
/// hyphens -- `1080p.BluRay.x264-CiNEFiLE`, `WEB-DL`, `FLAC2.0` -- and
/// prose is not: `Subscription`, `Rent, Buy`, `ADS`. One such join is
/// enough, and requiring one is what keeps an addon that writes a word in
/// its description from having that word for a headline.
///
/// A release with no join in it at all is missed, and falls back to the
/// name the list showed before. That is the safe way round: a name is
/// always something, and a wrong headline is read as the wrong file.
bool _looksLikeARelease(String text) =>
    RegExp(r'[A-Za-z0-9][._-][A-Za-z0-9]').hasMatch(text);

/// The containers an addon's filename actually ends in.
///
/// Named, rather than matched by shape. "A dot and two to four letters at
/// the end" is what a container looks like, and it is also what a codec
/// looks like: `Breaking.Bad.S01E01.1080p.WEB-DL.x265` ends in `.x265`,
/// which that shape reads as an extension and takes off, leaving a release
/// that ends `WEB-DL`. That is what kept the phone drawing the release
/// twice after it was supposedly fixed -- the title had `.x265` on it and
/// the line beneath, stripped of `.mkv` and then of `.x265`, did not, so
/// the two never compared equal. A list cannot make that mistake.
const Set<String> _containers = {
  '3gp',
  'asf',
  'avi',
  'divx',
  'flv',
  'img',
  'iso',
  'm2ts',
  'm4v',
  'mkv',
  'mov',
  'mp4',
  'mpeg',
  'mpg',
  'mts',
  'ogm',
  'ogv',
  'rm',
  'rmvb',
  'ts',
  'vob',
  'webm',
  'wmv',
};

/// [name] without the container extension an addon's filename carries, and
/// only that: a release ends in `-GROUP` or `.x265`, and neither is an
/// extension however much the second one looks like one.
String? _withoutExtension(String? name) {
  if (name == null) return null;
  final dot = name.lastIndexOf('.');
  if (dot < 1 || dot == name.length - 1) return name;
  return _containers.contains(name.substring(dot + 1).toLowerCase())
      ? name.substring(0, dot)
      : name;
}

/// The first line with anything on it; null when there is none.
String? _firstLine(String? text) {
  if (text == null) return null;
  for (final line in text.split('\n')) {
    if (line.trim().isNotEmpty) return line.trim();
  }
  return null;
}

/// [text] with its line breaks turned into spaces, so a two-line `name`
/// ("Torrentio\n4k") reads as one headline rather than laying out as two
/// on a card that has room for the release instead.
String? _oneLine(String? text) {
  if (text == null) return null;
  final joined = text.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
  return joined.isEmpty ? null : joined;
}
