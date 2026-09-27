/// The app's one byte formatter.
library;

/// [bytes] in the decimal units storage is sold and shown in (`32.8 kB`,
/// `1.4 GB`, `357 MB`), the same ladder the player's panel counts bitrate
/// and speed on: one decimal below 100 of a unit and none above it.
///
/// Every byte count the app draws goes through this -- a download's size,
/// free space, the image cache, the stats panel. Two exceptions, both
/// deliberate (`AGENTS.md`, the stats panel's units rule): piece lengths
/// are powers of two and are drawn in binary units
/// (`TorrentProgressCard.formatPieceSize`), and a stream pill repeats the
/// size text the addon wrote, which is 1024-based (`StreamFacts`).
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['kB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  // 999_999 B is 999.999 kB, which rounds to `1000 kB`: a unit that does
  // not exist. Promote it once more so it reads `1.0 MB`.
  if (value.round() >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}
