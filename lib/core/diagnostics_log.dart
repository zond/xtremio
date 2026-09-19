import 'dart:io' show InternetAddress;

import 'package:flutter/foundation.dart';

import '../src/rust/api/diagnostics.dart' as rust;

/// Where a Dart-side diagnostic line goes. The app installs the one that
/// writes into the Rust core's log ring ([DiagnosticsLog.useCoreRing]);
/// tests install a recorder; anything that has installed nothing drops the
/// line, which is what keeps a widget test off FFI without arranging
/// anything.
typedef DiagnosticsSink = void Function(
  String level,
  String target,
  String message,
);

/// The Dart half of the log the Diagnostics screen copies.
///
/// The Rust side keeps the ring (`rust/src/logging.rs`) and everything
/// below the FFI already lands in it. Playback, though, is decided up
/// here: which URL was opened, what mpv said when it refused, whether the
/// open is being retried, an unhandled Flutter error. None of that was in
/// the ring, so a copied report could not explain a playback failure -- the
/// one thing it is most often asked to explain.
///
/// Lines go through the FFI into the *same* ring, not a second buffer:
/// one clock, one format, one bound. Order is the order things happened in
/// because the call is synchronous and the ring is append-only.
///
/// **Nothing secret goes in.** No stremio-core action args, no auth
/// material, no manifest URL with a key (see `AGENTS.md`, "Never log auth
/// material"). **This class is where a URL is made safe to write**, and
/// it happens in [write], so every line -- ours, mpv's, an exception's
/// `toString` -- goes through the one rule ([DiagnosticsLog.url],
/// [DiagnosticsLog.redactUrls]) before it reaches the ring. The ring is
/// also what Android's logcat gets (`rust/src/logging.rs` re-emits every
/// app line there before it is stored), so a scrub any later than this --
/// in the Rust layer, or in `redactSecrets` on the way to the clipboard --
/// would be one that logcat never saw. `redactSecrets` is the second lock,
/// not the first.
abstract final class DiagnosticsLog {
  /// Where lines go. Null drops them.
  static DiagnosticsSink? sink;

  /// Whether URLs are written whole: set while Verbose logging is on
  /// (`DiagnosticsTraceSync`, the one place that follows the preference).
  ///
  /// Verbose logging is for chasing a problem, and the redaction below is
  /// exactly what hides the thing being chased -- the RD stream that mpv
  /// could not recognise could not be fetched again, because the log held
  /// `/proxy/d=<host>/...` and nothing else. So with it on, [url] hands the
  /// URL back as it is and the copied report skips its scrub
  /// (`formatDiagnostics`). The switch's own text says so: those URLs can
  /// carry an addon's debrid key. Lines written before it was turned on
  /// stay redacted, and the ones written while it was on are scrubbed by
  /// the report ([safeUrl]) once it is off again: they are still in the
  /// ring.
  static bool unredacted = false;

  /// The last line written, and how many identical ones have been
  /// swallowed since. A player that fails every frame, or a stall that
  /// repeats, must not push the rest of the session out of a 400-line ring.
  static String? _last;
  static int _repeats = 0;

  /// Sends Dart-side lines into the Rust core's log ring. Called once the
  /// Rust library is loaded; a call made before that (or with no core at
  /// all) is dropped rather than thrown, since a log line is never worth a
  /// crash.
  static void useCoreRing() {
    sink = (level, target, message) {
      try {
        rust.diagnosticsLog(level: level, target: target, message: message);
      } catch (_) {
        // No core, no ring. Nothing to do and nowhere to say it.
      }
    };
  }

  /// Records `message` under `target` (the Dart source: `player`,
  /// `flutter`) at `level` (`info`, `warn`, `error`, `debug`).
  ///
  /// A line identical to the one before it is counted instead of written;
  /// the count is written out as soon as something else happens.
  ///
  /// Every `http(s)` URL in [message] is rewritten by [url] on the way
  /// through ([redactUrls]). Callers still write their own URLs through
  /// [url] -- the rule is the same, and a line built from the safe form
  /// reads the same after this pass -- but the pass is what catches the
  /// text nobody composed: mpv's `Failed to open <url>`, media_kit's
  /// exception messages, a `PlatformException` naming what it was given.
  static void write(String level, String target, String message) {
    final sink = DiagnosticsLog.sink;
    if (sink == null) return;
    message = redactUrls(message);
    final line = '$level\x00$target\x00$message';
    if (line == _last) {
      _repeats++;
      return;
    }
    if (_repeats > 0) {
      final parts = _last!.split('\x00');
      final times = _repeats == 1 ? 'once' : '$_repeats times';
      sink(parts[0], parts[1], 'last line repeated $times');
      _repeats = 0;
    }
    _last = line;
    sink(level, target, message);
  }

  /// An ordinary event worth having in a report.
  static void info(String target, String message) =>
      write('info', target, message);

  /// Something that went wrong but was handled (an open being retried).
  static void warn(String target, String message) =>
      write('warn', target, message);

  /// Something that failed.
  static void error(String target, String message) =>
      write('error', target, message);

  /// [url] as it may be written into a log: scheme, host and port always,
  /// the path only where the path is ours, and never the query or any
  /// credentials.
  ///
  /// The query is where an addon's API key rides, and the userinfo is a
  /// password by definition. The path is the half that used to be kept
  /// whole, on the reasoning that the embedded server's own
  /// `/{infoHash}/{fileIdx}` is the useful bit of a report and carries
  /// nothing secret -- which is true of that path and false of every other
  /// one this app plays. A debrid link signs its token into a path segment,
  /// Torrentio and Comet put the debrid *API key* in theirs, and a stream
  /// proxied through the server carries the whole target path on the end
  /// of `/proxy/d=<origin>&p=<player token>/…`
  /// (`proxiedThroughServer`, `lib/core/stream_proxy.dart`), so the old
  /// rule wrote a working download link and the proxy's own token into
  /// the report the Diagnostics screen tells people to paste into an
  /// issue. So:
  ///
  /// - A `/proxy/…` URL keeps `scheme://host:port/proxy/d=<target host>/…`:
  ///   the target's host is what a report about a stream needs (which
  ///   debrid, which addon), and the `p=` token, the target path and its
  ///   query are what it must not have.
  /// - A URL on this device, or on the host and port of the LAN listener a
  ///   receiver is handed ([noteOwnServer]), keeps its path: that is the
  ///   server's `/{infoHash}/{fileIdx}`. Another private address is
  ///   somebody else's host like any other ([_isOurs]).
  /// - Anything else keeps only its origin: `https://host/…`. A path on
  ///   somebody else's host is a path this app did not write and cannot
  ///   vouch for.
  /// - A `file://` URL keeps only its last segment: the rest is the user's
  ///   directory layout, which no report needs.
  static String url(Uri url) => unredacted ? url.toString() : safeUrl(url);

  /// [url] as [url] writes it with Verbose logging off, whatever the
  /// switch says: what the copied report's scrub (`redactSecrets`) runs on
  /// every URL in it, so lines written whole while the switch was on do
  /// not leave in a report taken after it was turned off.
  static String safeUrl(Uri url) {
    if (url.isScheme('file')) {
      final segments = url.pathSegments;
      final name = segments.isEmpty ? '' : segments.last;
      return 'file://…/$name';
    }
    // `Uri.host` hands an IPv6 address back without its brackets.
    final host = url.host.contains(':') ? '[${url.host}]' : url.host;
    final authority = url.hasPort ? '$host:${url.port}' : host;
    final origin = '${url.scheme}://$authority';
    final segments = url.pathSegments;
    if (segments.isNotEmpty && segments.first == 'proxy') {
      final target = segments.length > 1 ? _proxyTargetHost(segments[1]) : '';
      return '$origin/proxy/d=$target/…';
    }
    final query = url.hasQuery ? '?…' : '';
    if (!_isOurs(url)) {
      return '$origin${url.path.isEmpty ? '' : '/…'}$query';
    }
    return '$origin${url.path}$query';
  }

  /// [text] with every `http(s)://…` in it rewritten by [url]. What
  /// [write] runs on every line; also for a caller that has a whole
  /// message from somewhere else (an exception's text) rather than a URL.
  ///
  /// A URL in prose is taken up to the next whitespace, and trailing
  /// sentence punctuation is handed back to the sentence: mpv writes
  /// `Failed to open <url>.` with the full stop on the URL. Text that does
  /// not parse as a URL is left as it was -- a token that only looks like
  /// one is not a place to invent a redaction, and the second lock is
  /// still there for it.
  ///
  /// [always] redacts with [safeUrl] whatever Verbose logging says; the
  /// report's scrub asks for that.
  static String redactUrls(String text, {bool always = false}) =>
      text.replaceAllMapped(_httpUrl, (match) {
        var written = match[0]!;
        var trailing = '';
        while (written.isNotEmpty &&
            _trailingPunctuation.contains(written[written.length - 1])) {
          trailing = written[written.length - 1] + trailing;
          written = written.substring(0, written.length - 1);
        }
        final parsed = Uri.tryParse(written);
        if (parsed == null || parsed.host.isEmpty) return match[0]!;
        return '${always ? safeUrl(parsed) : url(parsed)}$trailing';
      });

  static final RegExp _httpUrl = RegExp(r'https?://\S+', caseSensitive: false);
  static const String _trailingPunctuation = '.,;:!?)]}\'"`';

  /// The host inside a `/proxy` route's `d=` segment, or `…` when it does
  /// not read as one. [segment] is the decoded path segment, so the
  /// percent-encoding `proxiedThroughServer` wrote is already undone:
  /// `d=https://host:8080&p=token`.
  static String _proxyTargetHost(String segment) {
    if (!segment.startsWith('d=')) return '…';
    final origin = segment.substring(2).split('&').first;
    final host = Uri.tryParse(origin)?.host ?? '';
    return host.isEmpty ? '…' : host;
  }

  /// The servers of ours that are reachable at an address other than
  /// loopback: the LAN media listener, as `ServerClient.lanMediaBaseUrl`
  /// answers it for a receiver ([noteOwnServer]).
  static final Set<Uri> _ownServers = {};

  /// Says that [base] is one of this app's own servers, so a URL on its
  /// host and port keeps its path ([url]). Called with every LAN media
  /// base handed out; loopback needs no noting.
  static void noteOwnServer(Uri base) => _ownServers.add(
    Uri(scheme: base.scheme, host: base.host, port: base.port),
  );

  /// Whether [url]'s path is ours to write down: anything on this device
  /// (the embedded server over loopback), or the host *and port* of a
  /// server of ours that is reachable from the network ([noteOwnServer]).
  ///
  /// Not "any private address", which is what it used to be: an addon
  /// somebody hosts on their own LAN is on a private address too, and its
  /// path carries its config -- debrid key included -- the same as a
  /// public addon's does.
  static bool _isOurs(Uri url) {
    final host = url.host;
    if (host == 'localhost' ||
        (InternetAddress.tryParse(host)?.isLoopback ?? false)) {
      return true;
    }
    return _ownServers.any(
      (base) => base.host == host && base.port == url.port,
    );
  }

  /// Forgets what was last written. For tests, which share a process.
  static void reset() {
    _last = null;
    _repeats = 0;
    _ownServers.clear();
  }
}

/// Sends what Flutter and the Dart isolate would otherwise only print to
/// the console into the log ring as well.
///
/// A crash in a build, a listener or an async gap is exactly the kind of
/// failure nobody can read off a phone -- it goes to logcat, which is what
/// the whole Diagnostics screen exists to avoid needing. The existing
/// handlers stay in place (Flutter's own still prints the full details with
/// its stack); only the one line that says what broke is captured, because
/// a stack trace would fill the ring it is in.
///
/// Idempotent: installing twice does not chain two copies of this.
void captureUnhandledErrors() {
  if (_capturing) return;
  _capturing = true;
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    DiagnosticsLog.error(
      'flutter',
      '${details.exceptionAsString()}'
          '${details.context == null ? '' : ' (${details.context})'}',
    );
    previous?.call(details);
  };
  final previousPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    DiagnosticsLog.error('dart', '$error');
    return previousPlatform?.call(error, stack) ?? false;
  };
}

/// Whether [captureUnhandledErrors] has already run.
bool _capturing = false;
