import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_prefs_client.dart';

void main() {
  test('defaults to sectioned streams until something is loaded', () async {
    final prefs = AppPrefs(client: FakePrefsClient());
    expect(prefs.streamsSectioned, isTrue);
    await prefs.load();
    expect(prefs.streamsSectioned, isTrue);
  });

  test('load reads a stored choice and notifies', () async {
    final prefs = AppPrefs(
      client: FakePrefsClient({'streamsSectioned': false}),
    );
    var notified = 0;
    prefs.addListener(() => notified++);

    await prefs.load();

    expect(prefs.streamsSectioned, isFalse);
    expect(notified, 1);
  });

  test('a value set while the load is out is not overwritten by it', () async {
    // The app does not wait for the load before its first screens, and what
    // the load read is older than anything set since.
    final prefs = AppPrefs(
      client: FakePrefsClient({
        AppPrefs.streamsSectionedKey: true,
        AppPrefs.verboseDiagnosticsKey: true,
      }),
    );
    addTearDown(prefs.dispose);

    final loading = prefs.load();
    await prefs.setStreamsSectioned(false);
    // Absent from the file, where an absence reads as "nothing pending".
    await prefs.setDrivePendingSession('session-1');
    await loading;

    expect(prefs.streamsSectioned, isFalse);
    expect(prefs.drivePendingSession, 'session-1');
    expect(prefs.verboseDiagnostics, isTrue, reason: 'the rest is read');
  });

  test(
    'a change is written through and read back by a fresh AppPrefs',
    () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);

      await prefs.setStreamsSectioned(false);
      expect(client.stored['streamsSectioned'], isFalse);
      expect(client.writes, ['streamsSectioned']);

      // A fresh app start over the same file.
      final restarted = AppPrefs(client: client);
      await restarted.load();
      expect(restarted.streamsSectioned, isFalse);
    },
  );

  test('setting the value it already has writes nothing', () async {
    final client = FakePrefsClient();
    final prefs = AppPrefs(client: client);
    var notified = 0;
    prefs.addListener(() => notified++);

    await prefs.setStreamsSectioned(true);

    expect(client.writes, isEmpty);
    expect(notified, 0);
  });

  test('a stored value of the wrong type is ignored', () async {
    final prefs = AppPrefs(
      client: FakePrefsClient({'streamsSectioned': 'yes'}),
    );
    await prefs.load();
    expect(prefs.streamsSectioned, isTrue);
  });

  test('an unavailable file leaves the defaults and keeps the choice in '
      'memory', () async {
    final prefs = AppPrefs(client: FakePrefsClient.failing());

    await prefs.load();
    expect(prefs.streamsSectioned, isTrue);

    // The write fails too; the value still holds for this run rather than
    // snapping back under the user's finger.
    await prefs.setStreamsSectioned(false);
    expect(prefs.streamsSectioned, isFalse);
  });

  test(
    'with no client at all nothing is persisted and nothing throws',
    () async {
      final prefs = AppPrefs.inMemory();
      await prefs.load();
      await prefs.setStreamsSectioned(false);
      expect(prefs.streamsSectioned, isFalse);
    },
  );

  group('an install from before the rename', () {
    test('reads its choice from the old streamsFlat key when the new one is '
        'unset', () async {
      // True under the old `streamsFlat` key reads as this same sectioned
      // layout.
      final sectioned = AppPrefs(
        client: FakePrefsClient({'streamsFlat': true}),
      );
      await sectioned.load();
      expect(sectioned.streamsSectioned, isTrue);

      // False meant grouped, which stays grouped -- an old install's
      // deliberate choice is not reset by the rename.
      final grouped = AppPrefs(client: FakePrefsClient({'streamsFlat': false}));
      await grouped.load();
      expect(grouped.streamsSectioned, isFalse);
    });

    test('the new key wins when both are somehow present', () async {
      final prefs = AppPrefs(
        client: FakePrefsClient({
          'streamsFlat': false,
          'streamsSectioned': true,
        }),
      );
      await prefs.load();
      expect(prefs.streamsSectioned, isTrue);
    });

    test('a fresh choice is written under the new key only, leaving the '
        'old one untouched', () async {
      final client = FakePrefsClient({'streamsFlat': true});
      final prefs = AppPrefs(client: client);
      await prefs.load();

      await prefs.setStreamsSectioned(false);

      expect(client.stored['streamsSectioned'], isFalse);
      expect(
        client.stored['streamsFlat'],
        isTrue,
        reason: 'the old key is never written to again, just left stale',
      );
    });
  });

  group('which resolution sections are open', () {
    test('is null -- not empty -- until something is loaded or chosen', () {
      final prefs = AppPrefs(client: FakePrefsClient());
      expect(prefs.openStreamSections, isNull);
    });

    test('an absent key loads as null, an empty one as an empty set', () async {
      final unset = AppPrefs(client: FakePrefsClient());
      await unset.load();
      expect(
        unset.openStreamSections,
        isNull,
        reason: 'nothing chosen yet, not "chose to collapse everything"',
      );

      final collapsed = AppPrefs(
        client: FakePrefsClient({'openStreamSections': <String>[]}),
      );
      await collapsed.load();
      expect(
        collapsed.openStreamSections,
        isEmpty,
        reason: 'a deliberate, stored choice: collapse everything',
      );
      expect(collapsed.openStreamSections, isNotNull);
    });

    test('a stored choice round-trips through a fresh AppPrefs', () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);

      await prefs.setOpenStreamSections({'2160p', '1080p'});
      expect(client.stored['openStreamSections'], ['2160p', '1080p']);

      final restarted = AppPrefs(client: client);
      await restarted.load();
      expect(restarted.openStreamSections, {'2160p', '1080p'});
    });

    test('collapsing everything writes and reads back an empty set, not '
        'no key at all', () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);

      await prefs.setOpenStreamSections(const <String>{});

      expect(client.stored.containsKey('openStreamSections'), isTrue);
      expect(client.stored['openStreamSections'], isEmpty);

      final restarted = AppPrefs(client: client);
      await restarted.load();
      expect(restarted.openStreamSections, isEmpty);
      expect(restarted.openStreamSections, isNotNull);
    });

    test('setting the same set again writes nothing', () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);
      await prefs.setOpenStreamSections({'1080p'});
      final writesSoFar = client.writes.length;

      await prefs.setOpenStreamSections({'1080p'});

      expect(client.writes.length, writesSoFar);
    });
  });

  group('which addon groups are open', () {
    test('an absent key loads as null, an empty one as an empty set', () async {
      final unset = AppPrefs(client: FakePrefsClient());
      await unset.load();
      expect(
        unset.openStreamAddons,
        isNull,
        reason: 'nothing chosen yet, not "chose to close every group"',
      );

      final closed = AppPrefs(
        client: FakePrefsClient({'openStreamAddons': <String>[]}),
      );
      await closed.load();
      expect(
        closed.openStreamAddons,
        isEmpty,
        reason: 'a deliberate, stored choice: close everything',
      );
      expect(closed.openStreamAddons, isNotNull);
    });

    test('a stored choice round-trips through a fresh AppPrefs', () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);

      await prefs.setOpenStreamAddons({'https://alpha.example/manifest.json'});
      expect(client.stored['openStreamAddons'], [
        'https://alpha.example/manifest.json',
      ]);

      final restarted = AppPrefs(client: client);
      await restarted.load();
      expect(restarted.openStreamAddons, {
        'https://alpha.example/manifest.json',
      });
    });

    test('is a key of its own: neither choice reaches the other', () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);

      // An addon that happens to be called what a resolution is called --
      // which is exactly why these are two keys.
      await prefs.setOpenStreamAddons({'1080p'});
      expect(prefs.openStreamSections, isNull);

      await prefs.setOpenStreamSections({'2160p'});
      expect(prefs.openStreamAddons, {'1080p'});
      expect(client.stored['openStreamAddons'], ['1080p']);
      expect(client.stored['openStreamSections'], ['2160p']);

      final restarted = AppPrefs(client: client);
      await restarted.load();
      expect(restarted.openStreamAddons, {'1080p'});
      expect(restarted.openStreamSections, {'2160p'});
    });

    test('setting the same set again writes nothing', () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);
      await prefs.setOpenStreamAddons({'https://alpha.example/manifest.json'});
      final writesSoFar = client.writes.length;

      await prefs.setOpenStreamAddons({'https://alpha.example/manifest.json'});

      expect(client.writes.length, writesSoFar);
    });
  });

  testWidgets('PrefsScope hands the value down and rebuilds on a change', (
    tester,
  ) async {
    final prefs = AppPrefs(client: FakePrefsClient());
    addTearDown(prefs.dispose);
    final seen = <bool>[];

    await tester.pumpWidget(
      PrefsScope(
        prefs: prefs,
        child: Builder(
          builder: (context) {
            seen.add(PrefsScope.of(context).streamsSectioned);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(seen, [true]);

    await prefs.setStreamsSectioned(false);
    await tester.pump();
    expect(seen, [true, false]);
  });

  group('how strongly focus is marked', () {
    test('defaults to Standard, and an unknown name stays there', () async {
      final fresh = AppPrefs(client: FakePrefsClient());
      await fresh.load();
      expect(fresh.focusEmphasis, FocusEmphasis.standard);

      // A name a newer build wrote reads as "not set", not as a failure.
      final newer = AppPrefs(
        client: FakePrefsClient({'focusEmphasis': 'blinding'}),
      );
      await newer.load();
      expect(newer.focusEmphasis, FocusEmphasis.standard);
    });

    test('a choice round-trips through a fresh AppPrefs', () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);

      await prefs.setFocusEmphasis(FocusEmphasis.bold);
      expect(client.stored['focusEmphasis'], 'bold');
      expect(client.writes, ['focusEmphasis']);

      // The bad room is still a bad room after a restart.
      final restarted = AppPrefs(client: client);
      await restarted.load();
      expect(restarted.focusEmphasis, FocusEmphasis.bold);
    });

    test('choosing what is already chosen writes nothing', () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);
      await prefs.setFocusEmphasis(FocusEmphasis.standard);
      expect(client.writes, isEmpty);
    });
  });

  group('verbose diagnostics', () {
    // Off until chosen, read back from storage, written through once.
    test(
      'is off until something is loaded, and stays off with nothing stored',
      () async {
        final prefs = AppPrefs(client: FakePrefsClient());
        expect(prefs.verboseDiagnostics, isFalse);
        await prefs.load();
        expect(prefs.verboseDiagnostics, isFalse);
      },
    );

    test('load reads a stored choice and notifies', () async {
      final prefs = AppPrefs(
        client: FakePrefsClient({AppPrefs.verboseDiagnosticsKey: true}),
      );
      var notified = 0;
      prefs.addListener(() => notified++);

      await prefs.load();

      expect(prefs.verboseDiagnostics, isTrue);
      expect(notified, 1);
    });

    test(
      'a change is written through and read back by a fresh AppPrefs',
      () async {
        final client = FakePrefsClient();
        final prefs = AppPrefs(client: client);

        await prefs.setVerboseDiagnostics(true);
        expect(client.stored[AppPrefs.verboseDiagnosticsKey], isTrue);
        expect(client.writes, [AppPrefs.verboseDiagnosticsKey]);
        // The same value again writes nothing.
        await prefs.setVerboseDiagnostics(true);
        expect(client.writes, [AppPrefs.verboseDiagnosticsKey]);

        final restarted = AppPrefs(client: client);
        await restarted.load();
        expect(restarted.verboseDiagnostics, isTrue);
      },
    );
  });

  group('the Drive pairing', () {
    test('an unreadable list of linked files is nothing linked', () async {
      final prefs = AppPrefs(
        client: FakePrefsClient({
          AppPrefs.driveLinkedFilesKey: 'drive-file-1',
          AppPrefs.driveTokenDeadKey: 'yes',
        }),
      );
      addTearDown(prefs.dispose);

      await prefs.load();

      expect(prefs.driveLinkedFiles, LinkedDriveFiles.empty);
      expect(prefs.driveTokenDead, isFalse);
    });

    test(
      'nothing linked and no dead token are written as absent keys',
      () async {
        final client = FakePrefsClient({
          AppPrefs.driveLinkedFilesKey: [
            {'id': 'drive-file-1'},
          ],
          AppPrefs.driveTokenDeadKey: true,
        });
        final prefs = AppPrefs(client: client);
        addTearDown(prefs.dispose);
        await prefs.load();

        await prefs.setDriveLinkedFiles(LinkedDriveFiles.empty);
        await prefs.setDriveTokenDead(false);

        // A key that says the default in more bytes is a key removed, the
        // way the subtitle memories do it.
        expect(client.stored, isEmpty);
      },
    );
  });

  test('writes land in the order they were made, whichever one the file '
      'answers first', () async {
    // What the pairing job does: write the session id down, then forget
    // it. Each write is its own FFI call on a worker pool; unchained, the
    // second could land first and leave the id on disk for good.
    final client = _HeldPrefsClient();
    final prefs = AppPrefs(client: client);
    addTearDown(prefs.dispose);

    final first = prefs.setDrivePendingSession('session-1');
    final second = prefs.setDrivePendingSession(null);
    final third = prefs.setDriveTokenDead(true);
    await pumpEventQueue();
    expect(client.started, [
      AppPrefs.drivePendingSessionKey,
    ], reason: 'the second waits for the first, even on another key');

    client.held.single.complete();
    await pumpEventQueue();
    expect(client.started, [
      AppPrefs.drivePendingSessionKey,
      AppPrefs.drivePendingSessionKey,
    ]);
    client.held[1].complete();
    await Future.wait([first, second]);
    await pumpEventQueue();
    client.held[2].complete();
    await third;

    expect(client.stored.containsKey(AppPrefs.drivePendingSessionKey), isFalse);
    expect(client.stored[AppPrefs.driveTokenDeadKey], isTrue);
  });

  test('a write that fails does not stop the ones behind it', () async {
    final client = _HeldPrefsClient();
    final prefs = AppPrefs(client: client);
    addTearDown(prefs.dispose);

    final first = prefs.setDrivePendingSession('session-1');
    final second = prefs.setDrivePendingSession(null);
    await pumpEventQueue();
    client.held.single.completeError(StateError('disk full'));
    await first;
    await pumpEventQueue();
    client.held[1].complete();
    await second;

    expect(client.started, hasLength(2));
  });

  testWidgets('maybeOf is null with no scope above', (tester) async {
    AppPrefs? found = AppPrefs.inMemory();
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          found = PrefsScope.maybeOf(context);
          return const SizedBox.shrink();
        },
      ),
    );
    expect(found, isNull);
  });
}

/// A [PrefsClient] whose every write waits for the test to finish it, so a
/// test decides which of two writes the file answers first.
class _HeldPrefsClient implements PrefsClient {
  /// What the writes that finished left behind.
  final Map<String, Object?> stored = {};

  /// The key of every write that has begun, in order.
  final List<String> started = [];

  /// One per begun write, completed by the test.
  final List<Completer<void>> held = [];

  @override
  Future<Map<String, dynamic>> getAll() async => {};

  @override
  Future<void> set(String key, Object? value) async {
    started.add(key);
    final gate = Completer<void>();
    held.add(gate);
    await gate.future;
    if (value == null) {
      stored.remove(key);
    } else {
      stored[key] = value;
    }
  }
}
