/// How far ahead playback buffers.
///
/// The streaming server reads ahead of the play head by a window sized for a
/// healthy connection and a patient player. A spotty link — or a receiver
/// whose own buffer is shallower than mpv's — wants more of the file fetched
/// before it is needed; a fast link on mobile data wants less. The server
/// takes that choice as `?buffer=` on the stream URL (and as its own
/// `bufferProfile` setting, which this app does not use: the choice is the
/// viewer's, per playback, not the server's).
///
/// The last option is not a window at all. Past a point a bigger buffer stops
/// being an answer, and the honest one is to keep the file: [wholeFile] pins
/// the stream as an offline download — the same mechanism the Downloads
/// screen lists and deletes — while it plays.
library;

enum BufferAhead {
  /// The server's own default, and this app's.
  normal,

  /// Twice the read-ahead.
  large,

  /// Four times the read-ahead.
  maximum,

  /// Four times the read-ahead *and* the whole file kept on the device.
  wholeFile;

  /// The value the stream URL's `buffer=` parameter carries.
  ///
  /// [wholeFile] asks for the widest window the server has: the file is being
  /// fetched whole anyway, and playback should still be as far ahead of the
  /// play head as the server will read.
  String get wire => this == BufferAhead.wholeFile ? 'maximum' : name;

  /// What the setting is stored as (`AppPrefs.bufferAheadKey`). Unlike
  /// [wire], this tells [maximum] and [wholeFile] apart.
  String get stored => name;

  /// The choice in plain words.
  String get label => switch (this) {
    BufferAhead.normal => 'Normal',
    BufferAhead.large => 'Large',
    BufferAhead.maximum => 'Maximum',
    BufferAhead.wholeFile => 'Download the whole file',
  };

  /// One line on what it costs — every option here trades data and storage
  /// for smoothness, and the viewer is the one paying.
  String get description => switch (this) {
    BufferAhead.normal => 'Reads a little ahead. Least data used.',
    BufferAhead.large => 'Reads twice as far ahead. Uses more data.',
    BufferAhead.maximum =>
      'Reads four times as far ahead. Uses much more data and disk.',
    BufferAhead.wholeFile =>
      'Downloads and stores the whole file while you watch. '
          'It appears in Downloads, where you can delete it.',
  };

  /// Whether choosing this keeps the file on the device rather than only
  /// buffering it.
  bool get storesTheFile => this == BufferAhead.wholeFile;

  /// The stored spelling back to a choice; null for anything else, including
  /// a name a newer build wrote, so an unknown value reads as "not set".
  static BufferAhead? parse(Object? stored) {
    if (stored is! String) return null;
    for (final choice in BufferAhead.values) {
      if (choice.stored == stored) return choice;
    }
    return null;
  }
}

/// [url] with the `buffer=` parameter set to [choice].
///
/// Every other parameter survives, repeats included — a torrent URL carries
/// one `tr=` per tracker and one `f=` per file filter, and dropping any of
/// them would change which file plays and which trackers the engine gets.
/// An empty query (`…/0?`, which is what stremio-core writes for a torrent
/// with no trackers) contributes nothing rather than an empty pair.
Uri withBufferAhead(Uri url, BufferAhead choice) {
  final params = <String, List<String>>{};
  url.queryParametersAll.forEach((key, values) {
    if (key.isNotEmpty) params[key] = values;
  });
  params['buffer'] = [choice.wire];
  return url.replace(queryParameters: params);
}
