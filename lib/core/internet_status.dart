import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'diagnostics_log.dart';

/// Whether the app reaches the internet, and when it does, the address the
/// internet sees it at and the country that address is in.
///
/// **Asked of the internet, because nothing on this device knows it.** The
/// interfaces carry a LAN address behind a router. So it is one request to
/// Cloudflare's `cdn-cgi/trace`, which needs no key and answers with the
/// address and its country together -- no table of address ranges on the
/// device.
@immutable
sealed class InternetStatus {
  const InternetStatus();
}

/// Not checked yet: nothing to say either way.
final class InternetUnknown extends InternetStatus {
  const InternetUnknown();

  @override
  bool operator ==(Object other) => other is InternetUnknown;

  @override
  int get hashCode => (InternetUnknown).hashCode;
}

/// The check could not reach the internet.
final class InternetOffline extends InternetStatus {
  const InternetOffline();

  @override
  bool operator ==(Object other) => other is InternetOffline;

  @override
  int get hashCode => (InternetOffline).hashCode;
}

/// The check reached the internet, which saw the app at [ip].
final class InternetOnline extends InternetStatus {
  const InternetOnline({required this.ip, required this.country});

  /// As Cloudflare wrote it: dotted IPv4 or an IPv6 address.
  final String ip;

  /// ISO 3166-1 alpha-2, upper case, or null when Cloudflare named none it
  /// could place (`XX`) or named something that is not a country (`T1`,
  /// its code for Tor).
  final String? country;

  /// [country] as the two regional indicator symbols a flag is drawn from,
  /// or null with no country.
  String? get flag => country == null ? null : flagOf(country!);

  @override
  bool operator ==(Object other) =>
      other is InternetOnline && other.ip == ip && other.country == country;

  @override
  int get hashCode => Object.hash(ip, country);
}

/// The flag emoji of an ISO 3166-1 alpha-2 [code]: each letter moved to
/// its regional indicator symbol, which is all a flag emoji is.
String flagOf(String code) => String.fromCharCodes([
  for (final unit in code.toUpperCase().codeUnits) 0x1F1E6 + unit - 0x41,
]);

/// A `cdn-cgi/trace` answer read, or null when it carries no address.
///
/// The answer is `key=value` lines; only `ip` and `loc` are read.
InternetOnline? parseCloudflareTrace(String body) {
  String? ip;
  String? loc;
  for (final line in const LineSplitter().convert(body)) {
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final value = line.substring(eq + 1).trim();
    switch (line.substring(0, eq)) {
      case 'ip':
        ip = value;
      case 'loc':
        loc = value.toUpperCase();
    }
  }
  if (ip == null || ip.isEmpty) return null;
  final placed = loc != null && RegExp(r'^[A-Z]{2}$').hasMatch(loc);
  return InternetOnline(
    ip: ip,
    country: placed && loc != 'XX' && loc != 'T1' ? loc : null,
  );
}

/// Fetches the trace's body. Throws on anything but an answer.
typedef CloudflareTraceFetch = Future<String> Function();

/// The one trace endpoint asked.
final Uri cloudflareTraceEndpoint = Uri.parse(
  'https://www.cloudflare.com/cdn-cgi/trace',
);

/// [endpoint]'s body over `dart:io`, bounded by [timeout] at every step.
/// Throws when it does not answer 200.
///
/// [endpoint] is [cloudflareTraceEndpoint] everywhere but in a test.
Future<String> fetchCloudflareTrace({
  Uri? endpoint,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client
        .getUrl(endpoint ?? cloudflareTraceEndpoint)
        .timeout(timeout);
    request.headers.set(HttpHeaders.userAgentHeader, 'xtremio');
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('trace answered ${response.statusCode}');
    }
    return body;
  } finally {
    client.close(force: true);
  }
}

/// Checks the app's [InternetStatus], again whenever [recheck] is called.
///
/// **A failed check is [InternetOffline], whatever came before.** The last
/// [InternetOnline] is not kept: the internet is not reachable now,
/// whatever it was before.
///
/// **Only the newest check lands.** Two rechecks in flight -- a resume and
/// a tap -- may answer in either order, and the earlier one's answer is
/// about a network that may no longer be there.
///
/// The address itself is never logged; only that a check failed, and the
/// failure's type.
class InternetStatusCheck extends ChangeNotifier {
  InternetStatusCheck({this.fetch = fetchCloudflareTrace});

  final CloudflareTraceFetch fetch;

  InternetStatus _status = const InternetUnknown();
  InternetStatus get status => _status;

  int _generation = 0;
  bool _disposed = false;

  /// Checks again. Never throws.
  Future<void> recheck() async {
    final generation = ++_generation;
    InternetStatus status = const InternetOffline();
    try {
      status = parseCloudflareTrace(await fetch()) ?? const InternetOffline();
    } catch (error) {
      DiagnosticsLog.info(
        'network',
        'internet status check failed (${error.runtimeType})',
      );
    }
    if (_disposed || generation != _generation) return;
    if (status == _status) return;
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Hands the app's [InternetStatusCheck] down, and rebuilds whoever reads
/// it when the status changes.
class InternetStatusScope extends InheritedNotifier<InternetStatusCheck> {
  const InternetStatusScope({
    super.key,
    required InternetStatusCheck check,
    required super.child,
  }) : super(notifier: check);

  static InternetStatusCheck? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<InternetStatusScope>()
      ?.notifier;
}
