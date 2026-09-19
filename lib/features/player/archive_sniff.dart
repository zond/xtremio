import 'dart:async';
import 'dart:io';

/// A container the player cannot open, recognised by its first bytes.
///
/// Some sources serve a whole archive rather than the film inside it: a
/// debrid link to a `.rar` of a release, a torrent whose one big file is a
/// `.zip` or a disc image. mpv answers those with "Failed to recognize file
/// format", which says nothing to the person holding the remote. This names
/// the container instead, so the failure can say what the source is.
enum ArchiveKind {
  rar('RAR archive'),
  zip('ZIP archive'),
  sevenZip('7-Zip archive'),
  iso('disc image (ISO)');

  const ArchiveKind(this.label);

  /// How the failure names it.
  final String label;
}

/// How many leading bytes [archiveKindOf] needs to see all it can: an ISO
/// 9660 image carries its signature at the start of sector 16, 32769 bytes
/// in; every other kind in the first few.
const int archiveSniffBytes = _isoSignatureAt + 5;

const int _isoSignatureAt = 0x8001;

/// The kind of archive [head] (a file's first bytes) starts, or null.
///
/// Signatures:
///  * RAR 1.5 to 4 and RAR 5 both begin `Rar!` 0x1A 0x07;
///  * ZIP begins `PK` 0x03 0x04 (0x05 0x06 for an empty one, 0x07 0x08 for
///    the first part of a split one);
///  * 7-Zip begins `7z` 0xBC 0xAF 0x27 0x1C;
///  * ISO 9660 has `CD001` at byte 32769.
ArchiveKind? archiveKindOf(List<int> head) {
  bool at(int offset, List<int> bytes) {
    if (head.length < offset + bytes.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      if (head[offset + i] != bytes[i]) return false;
    }
    return true;
  }

  if (at(0, const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])) return ArchiveKind.rar;
  if (at(0, const [0x50, 0x4B]) &&
      (at(2, const [0x03, 0x04]) ||
          at(2, const [0x05, 0x06]) ||
          at(2, const [0x07, 0x08]))) {
    return ArchiveKind.zip;
  }
  if (at(0, const [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) {
    return ArchiveKind.sevenZip;
  }
  if (at(_isoSignatureAt, const [0x43, 0x44, 0x30, 0x30, 0x31])) {
    return ArchiveKind.iso;
  }
  return null;
}

/// Reads the start of [url] and says which archive it is, if any.
///
/// Asks for only the bytes [archiveKindOf] needs, and stops reading at that
/// many should the server ignore the range and send the whole file. Every
/// failure -- not HTTP, an error status, no answer within [timeout] -- is
/// null: this only ever improves a failure message, and a failure to
/// improve it leaves the message mpv gave.
Future<ArchiveKind?> sniffArchive(
  Uri url, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (url.scheme != 'http' && url.scheme != 'https') return null;
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await _sniff(client, url).timeout(timeout);
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<ArchiveKind?> _sniff(HttpClient client, Uri url) async {
  final request = await client.getUrl(url);
  request.headers.set(
    HttpHeaders.rangeHeader,
    'bytes=0-${archiveSniffBytes - 1}',
  );
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok &&
      response.statusCode != HttpStatus.partialContent) {
    return null;
  }
  final head = <int>[];
  await for (final chunk in response) {
    head.addAll(chunk);
    if (head.length >= archiveSniffBytes) break;
  }
  return archiveKindOf(head);
}

/// What the player says instead of mpv's own words when [kind] is what the
/// source turned out to be.
String archiveFailure(ArchiveKind kind) =>
    'this source is a ${kind.label}, which can\'t be played. '
    'Try another source.';
