import '../../core/core.dart';

/// The app version, passed at build time with
/// `--dart-define=XTREMIO_VERSION=$(grep ^version pubspec.yaml | cut -d' ' -f2)`.
/// Empty when nobody passed one.
const String kAppVersion = String.fromEnvironment('XTREMIO_VERSION');

/// The git commit, passed at build time with
/// `--dart-define=XTREMIO_GIT_COMMIT=$(git rev-parse --short HEAD)`.
const String kGitCommit = String.fromEnvironment('XTREMIO_GIT_COMMIT');

/// What replaces a value that must never be copied.
const String redactedMarker = '<redacted>';

/// Names whose value is a secret wherever it appears -- a log field, a JSON
/// object, a URL query. Ordered longest-first inside each family so
/// `auth_token` is not matched as the shorter `auth`.
const String _secretNames =
    r'auth[_-]?token|auth[_-]?key|access[_-]?token|refresh[_-]?token|'
    r'api[_-]?key|apikey|session[_-]?key|credentials?|'
    r'password|passwd|pwd|signature|secret|token|auth';

/// `Authorization: <anything>` -- the whole value, scheme included, so the
/// bearer token behind it cannot survive as a leftover word. A backtick
/// ends the value like a quote does: a log line that writes the header name
/// in prose (``control API requires `Authorization: Bearer <token>` ``)
/// must come out with its punctuation intact.
final RegExp _authorizationValue = RegExp(
  r'\b(authorization)("?\s*[:=]\s*)("?)([^"`,;\n]*)',
  caseSensitive: false,
);

/// A bearer token anywhere else it might be written out.
final RegExp _bearerToken = RegExp(
  r'\b(bearer)\s+[A-Za-z0-9\-._~+/=]+',
  caseSensitive: false,
);

/// `name=value`, `name: value` and `"name": "value"` for [_secretNames].
final RegExp _secretValue = RegExp(
  '\\b($_secretNames)("?\\s*[:=]\\s*)(?:"([^"]*)"|([^\\s,;&"\\)\\]}]+))',
  caseSensitive: false,
);

/// `"key": "..."`: stremio-core's session key is `ctx.profile.auth.key`, so
/// a bare `key` inside JSON is assumed to be it.
final RegExp _jsonKey = RegExp(
  r'"(key)"(\s*:\s*)"([^"]*)"',
  caseSensitive: false,
);

/// `key=<something long>`: a log field named `key` is usually a download's
/// meta id (short, with colons), but anything long and token-shaped is
/// treated as a secret rather than guessed about.
final RegExp _longKeyValue = RegExp(
  r'\b(key)(\s*[:=]\s*)[A-Za-z0-9\-._~+/=]{16,}',
  caseSensitive: false,
);

/// A value that is not a secret because it is not a value: an absent
/// field's `None`/`null`, an empty string, or a placeholder somebody wrote
/// into a message on purpose (`Authorization: Bearer <token>`).
///
/// The `Url` struct's `Debug` prints `password: None` for a URL with no
/// password in it, and blanking that says "a password was here" about a
/// line that says the opposite. Redaction has to leave harmless text alone
/// to stay readable enough to be worth reading.
final RegExp _nothingValue = RegExp(
  r'^(?:none|null|nil|undefined|)$|^(?:\w+\s+)?<[\w \-]+>$',
  caseSensitive: false,
);

/// Whether [value] is one of those -- surrounding quotes already stripped.
bool _isNothing(String value) => _nothingValue.hasMatch(value.trim());

/// Credentials in a URL's authority (`https://user:pass@host`).
final RegExp _urlUserInfo = RegExp(
  r'([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@',
  caseSensitive: false,
);

/// An addon's manifest URL with a path in front of `manifest.json`: that
/// path is where a debrid API key rides (`AGENTS.md`, "Deep links open an
/// addon"). The host stays -- it is what names the addon -- and the path
/// goes.
final RegExp _manifestUrl = RegExp(
  r'\b([a-z][a-z0-9+.-]*://[^/\s]+)/\S+/manifest\.json',
  caseSensitive: false,
);

/// Scrubs everything that must never reach the clipboard: the embedded
/// server's bearer token and any other `Authorization` value, auth and API
/// keys, passwords, and the path of an addon manifest URL.
///
/// Deliberately blunt. A false positive costs a line of context in a bug
/// report; a false negative puts a credential in a paste.
String redactSecrets(String text) => text
    .replaceAllMapped(
      _authorizationValue,
      (match) => _isNothing(match[4]!)
          ? match[0]!
          : '${match[1]}${match[2]}${match[3]}$redactedMarker',
    )
    .replaceAllMapped(_bearerToken, (match) => '${match[1]} $redactedMarker')
    .replaceAllMapped(
      _secretValue,
      (match) => switch (match[3] ?? match[4]!) {
        final value when _isNothing(value) => match[0]!,
        _ when match[3] != null => '${match[1]}${match[2]}"$redactedMarker"',
        _ => '${match[1]}${match[2]}$redactedMarker',
      },
    )
    .replaceAllMapped(
      _jsonKey,
      (match) => _isNothing(match[3]!)
          ? match[0]!
          : '"${match[1]}"${match[2]}"$redactedMarker"',
    )
    .replaceAllMapped(
      _longKeyValue,
      (match) => '${match[1]}${match[2]}$redactedMarker',
    )
    .replaceAllMapped(_urlUserInfo, (match) => '${match[1]}$redactedMarker@')
    .replaceAllMapped(
      _manifestUrl,
      (match) => '${match[1]}/$redactedMarker/manifest.json',
    );

/// The text the Diagnostics screen copies: a short header saying what this
/// build is and what the embedded server is doing, then the core's log
/// lines, oldest first. Everything in it has been through [redactSecrets].
String formatDiagnostics({
  required DiagnosticsSnapshot snapshot,
  required String platform,
  required String osVersion,
  required DateTime at,
  String appVersion = kAppVersion,
  String gitCommit = kGitCommit,
}) {
  final serverUrl = snapshot.serverBaseUrl;
  final header = <String>[
    'Xtremio diagnostics',
    'taken: ${at.toUtc().toIso8601String()}',
    'app: ${appVersion.isEmpty ? 'unknown' : appVersion}'
        '${gitCommit.isEmpty ? '' : ' (commit $gitCommit)'}',
    'core: xtremio_core ${snapshot.coreVersion}',
    'platform: $platform · $osVersion',
    'server: ${serverUrl == null ? 'not running' : 'running · $serverUrl'}',
    'stream-server: ${snapshot.streamServerRev ?? 'unknown'}',
    'stremio-core: ${snapshot.stremioCoreRev ?? 'unknown'}',
    'log: ${snapshot.logLines.length} lines, oldest first',
  ];
  return redactSecrets([...header, '', ...snapshot.logLines].join('\n'));
}
