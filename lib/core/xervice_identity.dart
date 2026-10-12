/// Proving to xtremio-xervice which Stremio account this device is signed
/// in as, and the one way the app asks it anything about that account.
///
/// The service keeps two things per account: the likes and dislikes (`faces`),
/// and the Drive grants. Both are behind a token of its own that
/// `POST /identity` hands out for the Stremio session key
/// (`xtremio-xervice/functions/account.js`). **The session key crosses to the
/// service once per token, to prove who this is, and is not kept there.** The
/// service asks Stremio whose key it is, keeps the account's user id in the
/// token, and forgets the key.
///
/// **Quiet by design.** Everything that goes through here is a background copy
/// of something the device already has. Signed out, offline, or a service that
/// will not answer is "nothing to sync this time", never a dialog.
/// [XerviceIdentity.send] answers null for all of them and logs which it was,
/// by kind and never by text.
///
/// **Never logged**: the session key ([stremioAuthKeyOf]) and the token.
/// Nothing here writes either into a line, a failure is logged by its type, and
/// `redactSecrets` knows both names (`authKey`, `token`) as the second lock.
library;

import 'dart:async';
import 'dart:io';

import 'diagnostics_log.dart';
import 'drive_pairing.dart';
import 'json_exchange.dart';

/// The Stremio session key of the signed-in account in a `ctx` state, or
/// null when nobody is signed in.
///
/// `ctx.profile.auth.key`. It is read here and nowhere else in the app.
/// `ProfileState` deliberately has no getter for it, because nothing on a
/// screen needs it, and this is the one place that sends it anywhere other than
/// Stremio. **Never log what this returns.**
String? stremioAuthKeyOf(Map<String, dynamic>? ctx) {
  final profile = ctx?['profile'];
  final auth = profile is Map ? profile['auth'] : null;
  final key = auth is Map ? auth['key'] : null;
  return key is String && key.isNotEmpty ? key : null;
}

/// One answer from the service: the status, and the body when it was a
/// JSON object.
final class XerviceAnswer {
  const XerviceAnswer(this.status, [this.json]);

  final int status;
  final Map<String, dynamic>? json;

  bool get ok => status >= 200 && status < 300;

  @override
  String toString() => 'XerviceAnswer($status)';
}

/// The service could not be asked: no network, a timeout, TLS. Carries the
/// type of what was thrown and nothing of its text, which can quote a URL.
final class XerviceUnreachable implements Exception {
  const XerviceUnreachable(this.kind);

  final String kind;

  @override
  String toString() => 'XerviceUnreachable($kind)';
}

/// How a request reaches the service. An interface so a test answers
/// without a network; [XerviceHttpClient] is the one the app uses.
abstract interface class XerviceHttp {
  /// One request to [path] on the service, with [body] as JSON and
  /// [bearer] as the `Authorization`. Throws [XerviceUnreachable] when
  /// nothing answered; any status that did answer is an [XerviceAnswer].
  Future<XerviceAnswer> send(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? bearer,
  });
}

/// [XerviceHttp] over `dart:io`, at the Hosting site that serves pairing.
final class XerviceHttpClient implements XerviceHttp {
  XerviceHttpClient({Uri? origin, this.timeout = const Duration(seconds: 15)})
    : origin = origin ?? Uri.parse(XtremioDrivePairingService.defaultOrigin);

  final Uri origin;
  final Duration timeout;

  /// Every answer here is a few hundred bytes; a body past this is not one
  /// of them.
  static const int maxAnswerBytes = 512 * 1024;

  @override
  Future<XerviceAnswer> send(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? bearer,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await () async {
        final answer = await sendWithoutRedirects(
          client,
          method,
          origin.resolve(path),
          body: body,
          bearer: bearer,
        );
        final json = await readJsonObject(answer, maxBytes: maxAnswerBytes);
        return XerviceAnswer(answer.statusCode, json);
      }().timeout(timeout);
    } on Object catch (error) {
      throw XerviceUnreachable(error.runtimeType.toString());
    } finally {
      client.close(force: true);
    }
  }
}

/// Holds the service's token for the signed-in account, renews it when it
/// has expired or the service refuses it, and sends the requests that need
/// it.
///
/// The token is bound to the session key it was made for. A sign-out, or a
/// sign-in as somebody else, is a key this did not see, and the token goes with
/// it. So a request is never sent as the previous account.
class XerviceIdentity {
  XerviceIdentity({
    required this.http,
    required this.authKey,
    this.now = DateTime.now,
  });

  final XerviceHttp http;

  /// The session key now, or null when signed out ([stremioAuthKeyOf] over
  /// the app's `ctx`). Asked on every request, so a sign-out is noticed at
  /// the next one.
  final String? Function() authKey;

  /// The clock a token's expiry is read against.
  final DateTime Function() now;

  /// How long before its stated expiry a token is renewed rather than
  /// sent: a token that expires in transit is a refusal and a second
  /// round trip.
  static const Duration renewAhead = Duration(minutes: 2);

  String? _token;
  DateTime? _expiresAt;

  /// The key [_token] was made for. Held only to compare against; never
  /// written anywhere.
  String? _madeFor;

  /// A renewal in flight, shared by every request that needs one.
  Future<String?>? _renewing;

  /// Whether a session key is there to prove anything with.
  bool get signedIn => authKey() != null;

  /// Drops the token, so the next request asks for a fresh one.
  void forget() {
    _token = null;
    _expiresAt = null;
    _madeFor = null;
  }

  /// A live token for the signed-in account, asking for one when the held
  /// one is missing, expiring, or for another key. Null when signed out,
  /// offline, or refused.
  Future<String?> token() async {
    final key = authKey();
    if (key == null) {
      forget();
      return null;
    }
    final held = _token;
    final expiresAt = _expiresAt;
    if (held != null &&
        _madeFor == key &&
        expiresAt != null &&
        now().toUtc().add(renewAhead).isBefore(expiresAt)) {
      return held;
    }
    return _renewing ??= _renew(key).whenComplete(() => _renewing = null);
  }

  Future<String?> _renew(String key) async {
    forget();
    final XerviceAnswer answer;
    try {
      answer = await http.send('POST', '/identity', body: {'authKey': key});
    } on XerviceUnreachable catch (error) {
      DiagnosticsLog.info('xervice', 'identity: not reachable (${error.kind})');
      return null;
    }
    final token = answer.json?['token'];
    final expiresAt = DateTime.tryParse('${answer.json?['expiresAt'] ?? ''}')
        ?.toUtc();
    if (!answer.ok || token is! String || token.isEmpty || expiresAt == null) {
      // 401 is a session Stremio does not know any more; anything else is
      // the service. Either way there is nothing to sync with this time.
      DiagnosticsLog.info('xervice', 'identity: refused (${answer.status})');
      return null;
    }
    // Still the same account: a sign-out while this was out must not leave
    // a token behind for the next one.
    if (authKey() != key) return null;
    _token = token;
    _expiresAt = expiresAt;
    _madeFor = key;
    return token;
  }

  /// [method] on [path] as the signed-in account: the answer, or null when
  /// there is no account to send as or the service could not be asked.
  ///
  /// A 401 is a token the service no longer takes: expired early, or signed
  /// with a key that has since been rotated. So the token is renewed and the
  /// request sent once more. A second 401 is answered as it is.
  Future<XerviceAnswer?> send(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final bearer = await token();
      if (bearer == null) return null;
      final XerviceAnswer answer;
      try {
        answer = await http.send(method, path, body: body, bearer: bearer);
      } on XerviceUnreachable catch (error) {
        DiagnosticsLog.info(
          'xervice',
          '$method $path: not reachable (${error.kind})',
        );
        return null;
      }
      if (answer.status != HttpStatus.unauthorized || attempt == 1) {
        return answer;
      }
      forget();
    }
    return null;
  }
}
