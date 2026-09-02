import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/server_client.dart';

import '../support/rust_lib.dart';

Future<Map<String, dynamic>> _getJson(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final response = await (await client.getUrl(url)).close();
    final body = await response.transform(utf8.decoder).join();
    expect(response.statusCode, 200, reason: body);
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

void main() {
  setUpAll(initRustForTests);

  test(
    'embedded server starts on an ephemeral port, answers, and stops',
    () async {
      final tmp = await Directory.systemTemp.createTemp('xtremio-server-test-');
      const server = ServerClient();
      addTearDown(() async {
        await server.stop();
        await tmp.delete(recursive: true);
      });

      expect(server.baseUrl, isNull);

      final url = await server.start(
        configDir: Directory('${tmp.path}/server'),
        cacheDir: Directory('${tmp.path}/cache/server'),
        port: 0,
      );
      expect(url.scheme, 'http');
      expect(url.host, '127.0.0.1');
      expect(url.port, isNot(0));
      expect(server.baseUrl, url);

      final heartbeat = await _getJson(url.resolve('heartbeat'));
      expect(heartbeat['success'], isTrue);

      await server.stop();
      expect(server.baseUrl, isNull);
    },
  );
}
