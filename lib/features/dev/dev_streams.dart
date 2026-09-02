/// Hand-built streams for proving playback without any third-party addon.
/// Both are Big Buck Bunny (Blender Foundation, CC-BY 3.0), served two ways:
/// a public torrent through the embedded stream-server, and a plain HTTPS
/// file played directly. Shapes are stremio-core `Stream` JSON, exactly what
/// an addon would return.
library;

abstract final class DevStreams {
  /// The well-known WebTorrent Big Buck Bunny torrent (1080p MP4, ~276 MB,
  /// heavily seeded). No `fileIdx`: the server picks the largest file.
  static const Map<String, dynamic> bigBuckBunnyTorrent = {
    'infoHash': 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c',
    'announce': [
      'udp://tracker.opentrackr.org:1337/announce',
      'udp://open.demonii.com:1337/announce',
      'udp://tracker.torrent.eu.org:451/announce',
      'udp://explodie.org:6969/announce',
      'udp://tracker.leechers-paradise.org:6969/announce',
    ],
    'name': 'Big Buck Bunny (torrent)',
    'description': 'Public torrent via the embedded stream-server',
  };

  /// A plain progressive MP4 over HTTPS; the direct-play path.
  static const Map<String, dynamic> bigBuckBunnyHttp = {
    'url': 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
    'name': 'Big Buck Bunny (HTTP)',
    'description': 'Direct HTTPS file, played without the server',
  };
}
