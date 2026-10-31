/// Whether people outside the local network can connect to this device to
/// share a torrent, as the embedded server sees it
/// (`ServerHandle::port_forwarding_status`; no HTTP route, the app is the
/// only thing that asks).
///
/// The server asks the router over UPnP to forward the port its BitTorrent
/// listener announces, on every device. A cellular network has no router to
/// ask, and many home routers have UPnP turned off. A torrent downloads either
/// way: without a forwarded port, only the peers this device dials take part.
/// That is why this is information, never an error. Read it when a screen
/// opens, or piggyback it on a poll that is already running, never on a timer
/// of its own.
class PortForwardingStatus {
  const PortForwardingStatus({
    required this.enabled,
    required this.searched,
    this.gateway,
    this.port,
    required this.held,
    this.error,
  });

  factory PortForwardingStatus.fromJson(Map<String, dynamic> json) =>
      PortForwardingStatus(
        enabled: json['enabled'] as bool? ?? false,
        searched: json['searched'] as bool? ?? false,
        gateway: json['gateway'] as String?,
        port: (json['port'] as num?)?.toInt(),
        held: json['held'] as bool? ?? false,
        error: json['error'] as String?,
      );

  /// Whether the server asks a router at all. False when the server is not
  /// running, and for a listener bound to loopback, which nothing off this
  /// device may reach. Both answer "nothing to ask" the same way.
  final bool enabled;

  /// Whether a search for a router has finished, whatever it found. Until one
  /// has, no router is not news.
  final bool searched;

  /// The name of the router that answered the latest search. Null when
  /// nothing answered, which is no router to ask, not a failure.
  final String? gateway;

  /// The port the server asks to have forwarded: the one its listener
  /// announces to peers.
  final int? port;

  /// Whether the router holds the mapping right now, so peers outside can
  /// reach this device.
  final bool held;

  /// Why the latest search failed or, failing that, why the router refused
  /// the mapping. Null once the failure clears.
  final String? error;

  /// The state in words a viewer reads. Settings shows this as it is; the
  /// player's stats panel and the Diagnostics report show [detail], which
  /// adds the error's own text. The wording lives only here.
  ///
  /// A held mapping wins over everything else. An error is the router's
  /// refusal when a router answered, and a failed search when none did; the
  /// error's text stays out of this line, because it is the server's and
  /// names protocols and addresses a Settings row should not. A router that
  /// answered with neither a hold nor an error has not said yes yet.
  String get line {
    if (!enabled) return 'Off';
    if (held) {
      return [
        gateway == null ? 'Open' : 'Open through $gateway',
        if (port != null) 'port $port',
      ].join(', ');
    }
    if (error != null) {
      return gateway == null
          ? 'Could not look for your router'
          : 'Your router refused';
    }
    if (!searched) return 'Asking your router…';
    if (gateway == null) {
      return 'No router answered, so only connections this device starts';
    }
    return 'Waiting for $gateway to open a port…';
  }

  /// [line] with the error's own text after it, for the stats panel and the
  /// Diagnostics report, where whoever reads it came for the detail.
  String get detail {
    final error = this.error;
    return error == null || held ? line : '$line: $error';
  }

  @override
  bool operator ==(Object other) =>
      other is PortForwardingStatus &&
      other.enabled == enabled &&
      other.searched == searched &&
      other.gateway == gateway &&
      other.port == port &&
      other.held == held &&
      other.error == error;

  @override
  int get hashCode =>
      Object.hash(enabled, searched, gateway, port, held, error);

  @override
  String toString() =>
      'PortForwardingStatus(enabled: $enabled, searched: $searched, '
      'gateway: $gateway, port: $port, held: $held, error: $error)';
}
