import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/downloads/destination.dart';

import '../support/fake_downloads_client.dart';

/// The platform default on Android: the app's own external files directory,
/// which the OS does not reclaim.
const String platformDefault = '/sdcard/files/downloads';

/// A folder on a card that can be out of the device.
const String card = '/storage/ABCD-1234/files/downloads';

void main() {
  /// A client that answers [platformDefault], as Android does.
  Future<String?> android() async => platformDefault;

  /// ... and a platform with no default of its own, as every desktop is.
  Future<String?> desktop() async => null;

  FakeDownloadsClient clientAt({
    DownloadDestination destination = const DownloadDestination.unset(),
    String? downloadsDir,
  }) =>
      FakeDownloadsClient(registry: DownloadsRegistry(destination: destination))
        ..settings = {'downloadsDir': downloadsDir};

  group('where the downloads go, at start-up', () {
    test(
      'a first run applies the platform default, and only the first',
      () async {
        final client = clientAt();
        addTearDown(client.dispose);

        expect(
          await applyDefaultDestination(client, resolve: android),
          DownloadDestinationOutcome.appliedPlatformDefault,
        );
        expect(client.defaultsApplied, [platformDefault]);
        expect(
          client.registry.destination,
          const DownloadDestination.platformDefault(platformDefault),
          reason: 'recorded as the app\'s doing, not as an answer',
        );

        // The next launch, with everything as the first one left it.
        expect(
          await applyDefaultDestination(client, resolve: android),
          DownloadDestinationOutcome.kept,
        );
        expect(client.directories, [platformDefault], reason: 'nothing again');
      },
    );

    test(
      'a platform with no default of its own asks the server nothing',
      () async {
        final client = clientAt();
        addTearDown(client.dispose);
        final calls = <String>[];
        client.callLog = calls;

        expect(
          await applyDefaultDestination(client, resolve: desktop),
          DownloadDestinationOutcome.nothing,
        );
        expect(client.directories, isEmpty);
        expect(calls, isNot(contains('downloads.directory')));
      },
    );

    test('an explicit "with the cache" survives a restart', () async {
      // The Downloads screen writes a null `downloadsDir` on purpose for
      // "Default (with the cache)". That is an answer, not an open question,
      // and applying the platform default over it would move the files.
      final client = clientAt();
      addTearDown(client.dispose);
      await client.setDirectory(null);

      expect(
        await applyDefaultDestination(client, resolve: android),
        DownloadDestinationOutcome.kept,
      );
      expect(client.directories, [null], reason: 'only the choice itself');
      expect(client.registry.destination, const DownloadDestination.cache());
      expect(await client.directory(), isNull);
    });

    test('an explicit folder survives a restart', () async {
      final client = clientAt();
      addTearDown(client.dispose);
      await client.setDirectory(card);

      expect(
        await applyDefaultDestination(client, resolve: android),
        DownloadDestinationOutcome.kept,
      );
      expect(client.directories, [card]);
      expect(await client.directory(), card);
    });

    test('a folder the server dropped at boot is asked for again', () async {
      // The server clears a `downloadsDir` it cannot prepare at boot -- a
      // card that is not in the device -- and persists the null. The card is
      // back, so the folder goes back too.
      final client = clientAt(
        destination: const DownloadDestination.explicit(card),
      );
      addTearDown(client.dispose);

      expect(
        await applyDefaultDestination(client, resolve: android),
        DownloadDestinationOutcome.restoredChoice,
      );
      expect(client.directories, [card]);
      expect(await client.directory(), card);
    });

    test(
      'a folder that is really gone is reported, not quietly replaced',
      () async {
        final client = clientAt(
          destination: const DownloadDestination.explicit(card),
        )..unusableDirectories.add(card);
        addTearDown(client.dispose);

        expect(
          await applyDefaultDestination(client, resolve: android),
          DownloadDestinationOutcome.choiceUnavailable,
        );
        expect(
          client.directories,
          [card, platformDefault],
          reason:
              'the card is gone, so the files go where the OS leaves them '
              'alone -- and never to the cache a null would have meant',
        );
        expect(await client.directory(), platformDefault);
        expect(
          client.registry.destination,
          const DownloadDestination.explicit(card),
          reason:
              'the folder chosen is still the folder chosen: the card may '
              'be back next time, and the screen can say which one is missing',
        );

        // Which is exactly what the next launch does with it.
        client.unusableDirectories.remove(card);
        expect(
          await applyDefaultDestination(client, resolve: android),
          DownloadDestinationOutcome.restoredChoice,
        );
        expect(await client.directory(), card);
      },
    );

    test('a destination nobody recorded is adopted, not overwritten', () async {
      // A build from before any of this was recorded left a `downloadsDir`
      // behind. It is where the downloads already are, so it stays -- and
      // being on record is what lets a later start-up put it back.
      final client = clientAt(downloadsDir: card);
      addTearDown(client.dispose);

      expect(
        await applyDefaultDestination(client, resolve: android),
        DownloadDestinationOutcome.adoptedExisting,
      );
      expect(await client.directory(), card, reason: 'nothing moved');
      expect(
        client.registry.destination,
        const DownloadDestination.explicit(card),
      );
      expect(client.defaultsApplied, isEmpty);
    });

    test('a default the server lost is applied again', () async {
      final client = clientAt(
        destination: const DownloadDestination.platformDefault(platformDefault),
      );
      addTearDown(client.dispose);

      expect(
        await applyDefaultDestination(client, resolve: android),
        DownloadDestinationOutcome.appliedPlatformDefault,
      );
      expect(client.defaultsApplied, [platformDefault]);
    });

    test('a server that cannot be asked changes nothing', () async {
      final client = clientAt()..directoryError = StateError('no server');
      addTearDown(client.dispose);

      expect(
        await applyDefaultDestination(client, resolve: android),
        DownloadDestinationOutcome.failed,
      );
      expect(client.directories, isEmpty);
    });

    test('a registry that cannot be read changes nothing', () async {
      final client = clientAt()..listError = StateError('no bridge');
      addTearDown(client.dispose);

      expect(
        await applyDefaultDestination(client, resolve: android),
        DownloadDestinationOutcome.failed,
      );
      expect(client.directories, isEmpty);
    });
  });
}
