import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// How far a download has come: [received] of [total] bytes, [total] 0
/// while nobody has said.
typedef UpdateDownloadProgress = void Function(int received, int total);

/// Why an update's file could not be had.
class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message);

  /// Said to the viewer as it is.
  final String message;

  @override
  String toString() => 'UpdateDownloadException: $message';
}

/// Fetches a release's file to [target], picking up a partial one left by
/// an earlier attempt, and checks it against GitHub's digest before
/// handing it over.
///
/// **Resume.** The bytes land in `<target>.part`. A second attempt asks for
/// the rest with a `Range` header, and appends only if the server answers
/// `206` from exactly that offset; a `200` is the whole file again and
/// starts over, and a `416` (the part is already as long as the file, or
/// longer) or a `206` from another offset throws the part away and asks
/// for the whole file. A connection that drops keeps the part. A body that
/// ends short is the digest's to catch. `HttpClient` follows
/// `browser_download_url`'s redirect to the host that holds the bytes and
/// takes the `Range` header with it.
///
/// **Nothing unverified is kept.** The finished part is hashed and renamed
/// to [target] only when its SHA-256 is [digest]; on a mismatch, or with no
/// digest to check against, it is deleted and this throws. An APK nobody
/// can vouch for is never handed to the installer.
class ApkDownloader {
  ApkDownloader({this.timeout = const Duration(seconds: 30)});

  /// For the connection and for any gap between two pieces of the body.
  final Duration timeout;

  HttpClient? _client;

  /// Stops a download in progress; it throws a cancelled
  /// [UpdateDownloadException] and keeps its part for the next attempt.
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  bool _cancelled = false;

  Future<File> download({
    required Uri url,
    required File target,
    required String? digest,
    int expectedSize = 0,
    UpdateDownloadProgress? onProgress,
  }) async {
    final expected = parseSha256Digest(digest);
    if (expected == null) {
      throw const UpdateDownloadException(
        'This release has no checksum to verify the download against, so it '
        'is not installed.',
      );
    }
    _cancelled = false;
    await target.parent.create(recursive: true);
    final part = File('${target.path}.part');
    try {
      await _fetch(url, part, expectedSize, onProgress);
    } on UpdateDownloadException {
      rethrow;
    } catch (error) {
      if (_cancelled) {
        throw const UpdateDownloadException('The download was cancelled.');
      }
      throw UpdateDownloadException(
        'The download stopped (${error.runtimeType}). Try again to pick it '
        'up where it left off.',
      );
    } finally {
      _client?.close(force: true);
      _client = null;
    }
    if (await sha256OfFile(part) != expected) {
      await _delete(part);
      throw const UpdateDownloadException(
        'The downloaded file does not match the release\'s checksum, so it '
        'was deleted and not installed.',
      );
    }
    await _delete(target);
    return part.rename(target.path);
  }

  Future<void> _fetch(
    Uri url,
    File part,
    int expectedSize,
    UpdateDownloadProgress? onProgress,
  ) async {
    final client = _client = HttpClient()..connectionTimeout = timeout;
    var have = await part.exists() ? await part.length() : 0;
    if (expectedSize > 0 && have > expectedSize) {
      await _delete(part);
      have = 0;
    }
    // Twice at most: once more after a 416 has thrown the part away.
    for (var attempt = 0; attempt < 2; attempt++) {
      final request = await client.getUrl(url).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'xtremio');
      if (have > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      }
      final response = await request.close().timeout(timeout);
      final status = response.statusCode;
      final partial = status == HttpStatus.partialContent;
      final resumes = partial && _rangeStart(response) == have;
      if (have > 0 &&
          (status == HttpStatus.requestedRangeNotSatisfiable ||
              (partial && !resumes))) {
        // The part is no start of this file, or not one the server will
        // continue: throw it away and ask for the whole file.
        await response.drain<void>();
        await _delete(part);
        have = 0;
        continue;
      }
      if (status != HttpStatus.ok && !resumes) {
        await response.drain<void>();
        throw UpdateDownloadException(
          'The download failed: the server answered $status.',
        );
      }
      if (!resumes) have = 0;
      final total = response.contentLength >= 0
          ? have + response.contentLength
          : expectedSize;
      final sink = part.openWrite(
        mode: resumes ? FileMode.append : FileMode.write,
      );
      var received = have;
      onProgress?.call(received, total);
      try {
        await for (final chunk in response.timeout(timeout)) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      return;
    }
    throw const UpdateDownloadException(
      'The server would not send the file from the start.',
    );
  }

  /// The first byte a `206` says it carries, from its
  /// `Content-Range: bytes start-end/size`.
  static int? _rangeStart(HttpClientResponse response) {
    final range = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = RegExp(r'^bytes (\d+)-').firstMatch(range ?? '');
    return match == null ? null : int.parse(match[1]!);
  }

  static Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Gone already, or not ours to delete: either way not in the way.
    }
  }
}

/// The lower-case hex of a GitHub asset digest (`sha256:<64 hex>`), null
/// when [digest] is missing or is some other algorithm.
String? parseSha256Digest(String? digest) {
  final match = RegExp(r'^sha256:([0-9a-fA-F]{64})$')
      .firstMatch(digest?.trim() ?? '');
  return match?[1]!.toLowerCase();
}

/// The SHA-256 of [file], lower-case hex, read in pieces.
Future<String> sha256OfFile(File file) async {
  final output = _DigestSink();
  final input = sha256.startChunkedConversion(output);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return output.digest.toString();
}

/// Where a chunked hash leaves its one result.
class _DigestSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
