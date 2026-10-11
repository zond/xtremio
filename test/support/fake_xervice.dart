import 'package:xtremio/core/core.dart';

/// One request a [FakeXervice] was sent, as it was sent.
final class XerviceRequest {
  const XerviceRequest(this.method, this.path, this.body, this.bearer);

  final String method;
  final String path;
  final Map<String, Object?>? body;
  final String? bearer;

  @override
  String toString() => '$method $path';
}

/// xtremio-xervice's account routes, in memory: `/identity` for the keys in
/// [accounts], and whatever [routes] answers for the rest.
///
/// A token is `token-<n>-<user>`; [expireTokens] makes every issued one
/// refused from then on, the way a rotated `IDENTITY_KEY` would.
class FakeXervice implements XerviceHttp {
  FakeXervice({Map<String, String>? accounts, DateTime Function()? now})
    : accounts = accounts ?? {},
      now = now ?? DateTime.now;

  /// Session key to user id: the keys Stremio would know.
  final Map<String, String> accounts;
  final DateTime Function() now;

  /// Every request, in order.
  final List<XerviceRequest> requests = [];

  /// Set to make every request fail as if the network were down.
  bool offline = false;

  /// While set, `/identity` waits for it before answering.
  Future<void>? holdIdentity;

  /// How long an issued token says it lives.
  Duration tokenLife = const Duration(hours: 1);

  /// The routes past `/identity`: given the request and the user id its
  /// token names (null for no or a refused token), the answer. Unset
  /// routes answer 404.
  XerviceAnswer Function(XerviceRequest request, String? user)? routes;

  int _issued = 0;
  final Set<String> _live = {};

  /// Every token issued so far is refused from now on.
  void expireTokens() => _live.clear();

  /// How many `/identity` calls were made.
  int get identityCalls =>
      requests.where((request) => request.path == '/identity').length;

  @override
  Future<XerviceAnswer> send(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? bearer,
  }) async {
    final request = XerviceRequest(method, path, body, bearer);
    requests.add(request);
    if (offline) throw const XerviceUnreachable('SocketException');
    if (path == '/identity') {
      await holdIdentity;
      final user = accounts[body?['authKey']];
      if (user == null) {
        return const XerviceAnswer(401, {'error': 'not a Stremio session'});
      }
      final token = 'token-${++_issued}-$user';
      _live.add(token);
      return XerviceAnswer(200, {
        'token': token,
        'expiresAt': now().toUtc().add(tokenLife).toIso8601String(),
      });
    }
    final user = bearer != null && _live.contains(bearer)
        ? bearer.split('-').skip(2).join('-')
        : null;
    if (user == null) {
      return const XerviceAnswer(401, {'error': 'identity needed'});
    }
    return routes?.call(request, user) ?? const XerviceAnswer(404);
  }
}
