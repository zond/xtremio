import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/update/apk_download.dart';

import '../../support/real_http.dart';

/// A release asset on the loopback: `/redirect` answers a 302 to `/apk`,
/// the way `browser_download_url` sends a client to the storage host, and
/// `/apk` serves [bytes], honouring `Range` unless [ranges] is off.
class AssetServer {
  AssetServer._(this._server, this.bytes);

  static Future<AssetServer> start(Uint8List bytes) async {
    final server = AssetServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      bytes,
    );
    server._server.listen(server._handle);
    addTearDown(() => server._server.close(force: true));
    return server;
  }

  final HttpServer _server;
  final Uint8List bytes;
  bool ranges = true;

  /// Answers every range with a `206` from the start of the file: a
  /// server that will not continue from where the part ends.
  bool wrongOffset = false;

  /// Every `Range` header `/apk` saw, null for none.
  final List<String?> rangesAsked = [];

  Uri get redirect => Uri.parse('http://127.0.0.1:${_server.port}/redirect');

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path == '/redirect') {
      response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, '/apk');
      await response.close();
      return;
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    rangesAsked.add(range);
    final start = int.tryParse(
      RegExp(r'^bytes=(\d+)-$').firstMatch(range ?? '')?[1] ?? '',
    );
    if (wrongOffset && start != null) {
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-${bytes.length - 1}/${bytes.length}',
        )
        ..contentLength = bytes.length
        ..add(bytes);
    } else if (ranges && start != null) {
      if (start >= bytes.length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${bytes.length - 1}/${bytes.length}',
        )
        ..contentLength = bytes.length - start
        ..add(bytes.sublist(start));
    } else {
      response
        ..contentLength = bytes.length
        ..add(bytes);
    }
    await response.close();
  }
}

void main() {
  late Directory dir;
  late File target;
  final bytes = Uint8List.fromList(List.generate(50000, (i) => i * 7 % 256));
  final digest = 'sha256:${sha256.convert(bytes)}';

  setUp(() async {
    useRealHttp();
    dir = await Directory.systemTemp.createTemp('xtremio-update-');
    addTearDown(() => dir.delete(recursive: true));
    target = File('${dir.path}/updates/xtremio-v0.1.14-arm64-v8a.apk');
  });

  test(
    'fetches through the redirect, verifies, and hands over the file',
    () async {
      final server = await AssetServer.start(bytes);
      final progress = <int>[];
      final file = await ApkDownloader().download(
        url: server.redirect,
        target: target,
        digest: digest,
        expectedSize: bytes.length,
        onProgress: (received, total) {
          expect(total, bytes.length);
          progress.add(received);
        },
      );
      expect(file.path, target.path);
      expect(await file.readAsBytes(), bytes);
      expect(progress.last, bytes.length);
      expect(File('${target.path}.part').existsSync(), isFalse);
    },
  );

  test('picks a stopped download up where it left off', () async {
    final server = await AssetServer.start(bytes);
    await target.parent.create(recursive: true);
    await File('${target.path}.part').writeAsBytes(bytes.sublist(0, 20000));
    final file = await ApkDownloader().download(
      url: server.redirect,
      target: target,
      digest: digest,
      expectedSize: bytes.length,
    );
    // The Range went to the host with the bytes, past the redirect.
    expect(server.rangesAsked, ['bytes=20000-']);
    expect(await file.readAsBytes(), bytes);
  });

  test('starts over when the server sends the whole file again', () async {
    final server = await AssetServer.start(bytes)
      ..ranges = false;
    await target.parent.create(recursive: true);
    // A part that is not even the start of this file: appending the whole
    // answer to it would be a corrupt APK.
    await File('${target.path}.part').writeAsBytes([1, 2, 3]);
    final progress = <(int, int)>[];
    final file = await ApkDownloader().download(
      url: server.redirect,
      target: target,
      digest: digest,
      onProgress: (received, total) => progress.add((received, total)),
    );
    expect(await file.readAsBytes(), bytes);
    // Counted from nothing, not from the part thrown away.
    expect(progress.first, (0, bytes.length));
    expect(progress.last, (bytes.length, bytes.length));
  });

  test('starts over when the server continues from somewhere else', () async {
    final server = await AssetServer.start(bytes)
      ..wrongOffset = true;
    await target.parent.create(recursive: true);
    await File('${target.path}.part').writeAsBytes(bytes.sublist(0, 20000));
    final file = await ApkDownloader().download(
      url: server.redirect,
      target: target,
      digest: digest,
    );
    expect(server.rangesAsked, ['bytes=20000-', null]);
    expect(await file.readAsBytes(), bytes);
  });

  test('a part longer than the file GitHub lists is not resumed', () async {
    final server = await AssetServer.start(bytes);
    await target.parent.create(recursive: true);
    await File('${target.path}.part').writeAsBytes([...bytes, 1, 2, 3]);
    final file = await ApkDownloader().download(
      url: server.redirect,
      target: target,
      digest: digest,
      expectedSize: bytes.length,
    );
    expect(server.rangesAsked, [null]);
    expect(await file.readAsBytes(), bytes);
  });

  test('a dropped connection keeps the part for the next attempt', () async {
    // A raw socket, because an HttpServer will not end a body short.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) async {
      await socket.first;
      socket
        ..write(
          'HTTP/1.1 200 OK\r\n'
          'Content-Length: ${bytes.length}\r\n'
          '\r\n',
        )
        ..add(bytes.sublist(0, 1000));
      await socket.flush();
      await socket.close();
    });
    await expectLater(
      ApkDownloader().download(
        url: Uri.parse('http://127.0.0.1:${server.port}/apk'),
        target: target,
        digest: digest,
      ),
      throwsA(
        isA<UpdateDownloadException>().having(
          (e) => e.message,
          'message',
          startsWith('The download stopped ('),
        ),
      ),
    );
    expect(File('${target.path}.part').lengthSync(), 1000);
    expect(target.existsSync(), isFalse);
  });

  test('a part as long as the file is fetched again, not kept', () async {
    final server = await AssetServer.start(bytes);
    await target.parent.create(recursive: true);
    await File('${target.path}.part').writeAsBytes(bytes);
    // Too long for the size GitHub reported would be dropped up front; one
    // the server calls unsatisfiable is dropped on its 416.
    final file = await ApkDownloader().download(
      url: server.redirect,
      target: target,
      digest: digest,
    );
    expect(server.rangesAsked, ['bytes=50000-', null]);
    expect(await file.readAsBytes(), bytes);
  });

  test(
    'a file that does not match its digest is deleted, not handed over',
    () async {
      final server = await AssetServer.start(bytes);
      await expectLater(
        ApkDownloader().download(
          url: server.redirect,
          target: target,
          digest: 'sha256:${'00' * 32}',
        ),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.message,
            'message',
            "The downloaded file does not match the release's checksum, so it "
                'was deleted and not installed.',
          ),
        ),
      );
      expect(target.existsSync(), isFalse);
      expect(File('${target.path}.part').existsSync(), isFalse);
    },
  );

  test('with no digest to check against nothing is downloaded', () async {
    final server = await AssetServer.start(bytes);
    for (final missing in [null, '', 'sha1:${'ab' * 20}']) {
      await expectLater(
        ApkDownloader().download(
          url: server.redirect,
          target: target,
          digest: missing,
        ),
        throwsA(isA<UpdateDownloadException>()),
        reason: '$missing',
      );
    }
    expect(server.rangesAsked, isEmpty);
  });

  test('a server error is a message, and keeps nothing', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    });
    await expectLater(
      ApkDownloader().download(
        url: Uri.parse('http://127.0.0.1:${server.port}/apk'),
        target: target,
        digest: digest,
      ),
      throwsA(
        isA<UpdateDownloadException>().having(
          (e) => e.message,
          'message',
          'The download failed: the server answered 404.',
        ),
      ),
    );
    expect(target.existsSync(), isFalse);
  });

  test('the digest parses GitHub\'s spelling only', () {
    expect(parseSha256Digest('sha256:${'AB' * 32}'), 'ab' * 32);
    expect(parseSha256Digest('sha256:abc'), isNull);
    expect(parseSha256Digest('ab' * 32), isNull);
    expect(parseSha256Digest(null), isNull);
  });
}
