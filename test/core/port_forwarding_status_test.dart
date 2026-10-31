import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

/// What the server's `PortForwardingStatus` JSON reads as, and the words each
/// state is said in. Settings, the stats panel and Diagnostics all show
/// [PortForwardingStatus.line], so its copy is pinned here, verbatim.
void main() {
  group('fromJson', () {
    test('reads every field the server writes', () {
      final status = PortForwardingStatus.fromJson({
        'enabled': true,
        'searched': true,
        'gateway': 'FRITZ!Box 7590',
        'port': 45810,
        'held': true,
        'error': null,
      });
      expect(
        status,
        const PortForwardingStatus(
          enabled: true,
          searched: true,
          gateway: 'FRITZ!Box 7590',
          port: 45810,
          held: true,
        ),
      );
    });

    test('carries an error through', () {
      final status = PortForwardingStatus.fromJson({
        'enabled': true,
        'searched': true,
        'error': 'no route to host',
      });
      expect(status.error, 'no route to host');
      expect(status.gateway, isNull);
    });

    test('reads missing fields as off, nothing found and nothing held', () {
      expect(
        PortForwardingStatus.fromJson(const {}),
        const PortForwardingStatus(
          enabled: false,
          searched: false,
          held: false,
        ),
      );
    });
  });

  group('line', () {
    test('says off when the server asks no router', () {
      // Even with stale fields beside it: off is off.
      expect(
        const PortForwardingStatus(
          enabled: false,
          searched: true,
          gateway: 'FRITZ!Box 7590',
          port: 45810,
          held: true,
        ).line,
        'Off',
      );
    });

    test('names the router and the port once the router holds it', () {
      expect(
        const PortForwardingStatus(
          enabled: true,
          searched: true,
          gateway: 'FRITZ!Box 7590',
          port: 45810,
          held: true,
        ).line,
        'Open through FRITZ!Box 7590, port 45810',
      );
    });

    test('says open with whatever half of that is known', () {
      expect(
        const PortForwardingStatus(
          enabled: true,
          searched: true,
          port: 45810,
          held: true,
        ).line,
        'Open, port 45810',
      );
      expect(
        const PortForwardingStatus(
          enabled: true,
          searched: true,
          gateway: 'FRITZ!Box 7590',
          held: true,
        ).line,
        'Open through FRITZ!Box 7590',
      );
    });

    test('is asking before the first search has finished', () {
      expect(
        const PortForwardingStatus(
          enabled: true,
          searched: false,
          held: false,
        ).line,
        'Asking your router…',
      );
    });

    test('says what it means when no router answered', () {
      expect(
        const PortForwardingStatus(
          enabled: true,
          searched: true,
          held: false,
        ).line,
        'No router answered, so only connections this device starts',
      );
    });

    test('is the router refusing when a router answered with an error', () {
      expect(
        const PortForwardingStatus(
          enabled: true,
          searched: true,
          gateway: 'FRITZ!Box 7590',
          port: 45810,
          held: false,
          error: 'conflict in mapping entry',
        ).line,
        'Your router refused: conflict in mapping entry',
      );
    });

    test('is a failed search when an error stands and no router answered', () {
      expect(
        const PortForwardingStatus(
          enabled: true,
          searched: true,
          held: false,
          error: 'no route to host',
        ).line,
        'Could not look for your router: no route to host',
      );
    });

    test('waits on a router that answered and has not said yes yet', () {
      expect(
        const PortForwardingStatus(
          enabled: true,
          searched: true,
          gateway: 'FRITZ!Box 7590',
          port: 45810,
          held: false,
        ).line,
        'Waiting for FRITZ!Box 7590 to open a port…',
      );
    });
  });
}
