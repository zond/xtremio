/// One request to a service that answers JSON directly, and the capped
/// read of what it answers: what the pairing service, the Drive listing and
/// the archive routes each need, written once.
library;

import 'dart:convert';
import 'dart:io';

/// Sends one request and never follows a redirect.
///
/// Every route asked through this answers directly, and a followed
/// redirect is how an `Authorization` header ends up at a host nobody
/// meant to send it to. A redirect is handed back as it came, for the
/// caller to read as the non-`200` it is -- or, for the archive routes,
/// as the member's `Location`.
Future<HttpClientResponse> sendWithoutRedirects(
  HttpClient client,
  String method,
  Uri url, {
  Map<String, Object?>? body,
  String? bearer,
}) async {
  final request = await client.openUrl(method, url);
  request.followRedirects = false;
  if (bearer != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
  }
  if (body != null) {
    final bytes = utf8.encode(jsonEncode(body));
    request.headers.contentType = ContentType.json;
    request.contentLength = bytes.length;
    request.add(bytes);
  }
  return request.close();
}

/// [answer]'s body as a JSON object, or null when it is not one or is
/// longer than [maxBytes].
///
/// The body is read to its end even past the cap, so the connection is
/// finished with rather than abandoned half-read. Nothing here bounds the
/// time that takes: a caller times the whole exchange, body included.
Future<Map<String, dynamic>?> readJsonObject(
  HttpClientResponse answer, {
  required int maxBytes,
}) async {
  final bytes = <int>[];
  var tooBig = false;
  await for (final chunk in answer) {
    if (tooBig) continue;
    bytes.addAll(chunk);
    tooBig = bytes.length > maxBytes;
  }
  if (tooBig) return null;
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  } on Object {
    return null;
  }
}
