import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/local/android_local_media_source.dart';
import 'package:xtremio/features/local/desktop_local_media_source.dart';
import 'package:xtremio/features/local/local_folders_section.dart';
import 'package:xtremio/features/local/local_media.dart';

import '../support/fake_local_media_source.dart';
import '../support/fake_prefs_client.dart';

/// Cinemeta as a test tells it: Arrival (2016) for "Arrival", nothing for
/// anything else.
Future<List<Map<String, dynamic>>> _cinemeta(String type, String query) async =>
    query.toLowerCase() == 'arrival'
    ? [
        {
          'id': 'tt2543164',
          'type': 'movie',
          'name': 'Arrival',
          'releaseInfo': '2016',
        },
      ]
    : const [];

/// How this device's videos are found, asked for and matched: the service
/// ([LocalMedia]), each platform's source, and Settings' folder list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const arrivalUri = 'content://media/external/video/media/7';
  const holidayUri = 'content://media/external/video/media/8';

  Future<AppPrefs> prefs() async {
    final prefs = AppPrefs(client: FakePrefsClient());
    addTearDown(prefs.dispose);
    await prefs.load();
    return prefs;
  }

  group('LocalMedia', () {
    test('start-up never asks: a refresh without [ask] scans only what is '
        'already allowed', () async {
      final source = FakeLocalMediaSource(
        accessNow: LocalMediaAccess.askable,
        files: [localFacts(arrivalUri, 'Arrival.2016.1080p.mkv')],
      );
      final media = LocalMedia(
        prefs: await prefs(),
        source: source,
        search: _cinemeta,
      );
      addTearDown(media.dispose);

      await media.refresh();
      expect(source.requests, 0, reason: 'no prompt on launch');
      expect(source.scans, 0);
      expect(media.accessState, LocalMediaAccess.askable);

      await media.refresh(ask: true);
      expect(source.requests, 1);
      expect(media.accessState, LocalMediaAccess.granted);
      expect(media.files.entries, hasLength(1));
    });

    test('a scan is matched by name, and a name nothing matches is asked '
        'about once', () async {
      var searches = 0;
      Future<List<Map<String, dynamic>>> counting(String type, String query) {
        searches++;
        return _cinemeta(type, query);
      }

      final source = FakeLocalMediaSource(
        files: [
          localFacts(arrivalUri, 'Arrival.2016.1080p.mkv'),
          localFacts(holidayUri, 'Holiday Party.mkv'),
        ],
      );
      final media = LocalMedia(
        prefs: await prefs(),
        source: source,
        search: counting,
      );
      addTearDown(media.dispose);

      await media.refresh();
      expect(media.files.forUri(arrivalUri)!.match?.cinemetaId, 'tt2543164');
      expect(media.files.forUri(holidayUri)!.match, isNull);
      expect(media.files.forUri(holidayUri)!.checked, isTrue);
      final asked = searches;

      await media.refresh();
      expect(searches, asked, reason: 'every file was answered already');
    });

    test('a catalogue that cannot be reached leaves the file for the next '
        'refresh', () async {
      var reachable = false;
      Future<List<Map<String, dynamic>>> flaky(String type, String query) {
        if (!reachable) throw const SocketException('down');
        return _cinemeta(type, query);
      }

      final media = LocalMedia(
        prefs: await prefs(),
        source: FakeLocalMediaSource(
          files: [localFacts(arrivalUri, 'Arrival.2016.1080p.mkv')],
        ),
        search: flaky,
      );
      addTearDown(media.dispose);

      await media.refresh();
      expect(media.files.forUri(arrivalUri)!.checked, isFalse);

      reachable = true;
      await media.refresh();
      expect(media.files.forUri(arrivalUri)!.match?.cinemetaId, 'tt2543164');
    });

    test('a refresh asked for during a scan is a scan after it: a folder '
        'added meanwhile is not missed', () async {
      final source = FakeLocalMediaSource()..holdScan = Completer<void>();
      final media = LocalMedia(
        prefs: await prefs(),
        source: source,
        search: _cinemeta,
      );
      addTearDown(media.dispose);

      final first = media.refresh();
      await pumpEventQueue();
      expect(media.scanning, isTrue);
      source.files = [localFacts(arrivalUri, 'Arrival.2016.1080p.mkv')];
      final second = media.refresh();
      source.holdScan!.complete();
      await Future.wait([first, second]);

      expect(source.scans, 2);
      expect(media.files.entries, hasLength(1));
      expect(media.scanning, isFalse);
    });

    test('a source that fails is a list with nothing new in it', () async {
      final media = LocalMedia(
        prefs: await prefs(),
        source: _ThrowingSource(),
        search: _cinemeta,
      );
      addTearDown(media.dispose);
      await media.refresh(ask: true);
      expect(media.accessState, LocalMediaAccess.unavailable);
      expect(media.files.entries, isEmpty);
    });
  });

  group('Android', () {
    const channel = MethodChannel('xtremio/local_media');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('reads the channel\'s answers and rows, skipping a row with no '
        'address or name', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return switch (call.method) {
          'access' => 'askable',
          'requestAccess' => 'partial',
          'scan' => [
            {
              'uri': arrivalUri,
              'name': 'Arrival.2016.mkv',
              'size': 123,
              'durationMillis': 6960000,
              'height': 1080,
            },
            {'uri': holidayUri, 'name': 'Holiday.mp4', 'height': null},
            {
              'uri': 'content://x/10',
              'name': 'pappas.pengar.s01e07.mkv',
              'folder': 'Sample',
            },
            {'uri': 'content://x/11', 'name': 'sample-arrival.mkv'},
            {'name': 'no address.mkv'},
            {'uri': 'content://x/9'},
          ],
          _ => null,
        };
      });
      const source = AndroidLocalMediaSource();
      expect(await source.access(), LocalMediaAccess.askable);
      expect(await source.requestAccess(), LocalMediaAccess.partial);
      final rows = await source.scan();
      expect(rows, [
        (
          uri: arrivalUri,
          name: 'Arrival.2016.mkv',
          size: 123,
          durationMillis: 6960000,
          height: 1080,
        ),
        localFacts(holidayUri, 'Holiday.mp4'),
      ]);
    });
  });

  group('Android thumbnails', () {
    const channel = MethodChannel('xtremio/local_media');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('are the system\'s bytes, and a refusal is none', () async {
      final asked = <Object?>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        asked.add(call.arguments);
        if (call.arguments['uri'] == holidayUri) {
          throw PlatformException(code: 'gone');
        }
        return Uint8List.fromList([1, 2, 3]);
      });
      const source = AndroidLocalMediaSource();
      expect(await source.thumbnail(arrivalUri, size: 480), [1, 2, 3]);
      expect(await source.thumbnail(holidayUri, size: 480), isNull);
      expect(asked.first, {'uri': arrivalUri, 'size': 480});
    });
  });

  group('a desktop', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('local-media'));
    tearDown(() => root.deleteSync(recursive: true));

    File touch(String path) => File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');

    test('walks the chosen folders for videos, and nothing else', () async {
      touch('Films/Arrival (2016)/Arrival.2016.1080p.MKV');
      touch('Films/Arrival (2016)/Arrival.2016.1080p.srt');
      touch('Series/Breaking Bad/Season 1/Breaking.Bad.S01E01.mp4');
      touch('Films/.hidden/secret.mkv');
      touch('Films/.dot.mkv');
      touch('Films/notes.txt');
      touch('Elsewhere/not-chosen.mkv');
      final p = await prefs();
      await p.setLocalFolders([
        '${root.path}/Films',
        '${root.path}/Series',
        '${root.path}/Gone',
      ]);
      final source = DesktopLocalMediaSource(prefs: p);

      expect(await source.access(), LocalMediaAccess.granted);
      final found = await source.scan();
      expect(
        [for (final file in found) file.name],
        ['Arrival.2016.1080p.MKV', 'Breaking.Bad.S01E01.mp4'],
      );
      expect(found.first.uri, startsWith('file:///'));
      expect(found.first.size, 1);
      expect(
        File.fromUri(Uri.parse(found.first.uri)).existsSync(),
        isTrue,
        reason: 'the address is the file\'s own',
      );
    });

    test('a release\'s sample clip is not listed', () async {
      touch('Films/Arrival.2016/Sample/arrival.sample.mkv');
      touch('Films/Arrival.2016/Sample/whatever.mkv');
      touch('Films/Arrival.2016/sample-arrival.mkv');
      touch('Films/Arrival.2016/Arrival.2016.mkv');
      // A title with the word in it is a title.
      touch('Films/The.Sample.Man.2020.mkv');
      final p = await prefs();
      await p.setLocalFolders(['${root.path}/Films']);
      final found = await DesktopLocalMediaSource(prefs: p).scan();
      expect(
        [for (final file in found) file.name],
        ['Arrival.2016.mkv', 'The.Sample.Man.2020.mkv'],
      );
    });

    test('with no folder chosen there is nothing to ask and nothing to '
        'scan', () async {
      final source = DesktopLocalMediaSource(prefs: await prefs());
      expect(await source.access(), LocalMediaAccess.unavailable);
      expect(await source.requestAccess(), LocalMediaAccess.unavailable);
      expect(await source.scan(), isEmpty);
    });

    test('a name with spaces and accents comes back as it is', () async {
      touch('Films/Amélie (2001).mkv');
      final p = await prefs();
      await p.setLocalFolders(['${root.path}/Films']);
      final found = await DesktopLocalMediaSource(prefs: p).scan();
      expect(found.single.name, 'Amélie (2001).mkv');
    });
  });

  group('Settings → Local', () {
    Future<(AppPrefs, LocalMedia, FakeLocalMediaSource)> setUpMedia() async {
      final p = await prefs();
      final source = FakeLocalMediaSource(
        files: [localFacts(arrivalUri, 'Arrival.2016.1080p.mkv')],
      );
      final media = LocalMedia(prefs: p, source: source, search: _cinemeta);
      addTearDown(media.dispose);
      return (p, media, source);
    }

    testWidgets('a folder picked is kept and looked in at once; one dropped '
        'is looked in no more', (tester) async {
      final (p, media, source) = await setUpMedia();
      final picks = ['/home/me/Films', '/home/me/Films', null];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocalFoldersSection(
              prefs: p,
              media: media,
              pickFolder: () async => picks.removeAt(0),
            ),
          ),
        ),
      );
      expect(
        find.text('Where your videos are, for the Library\'s Local list'),
        findsOneWidget,
      );

      await tester.tap(find.text(LocalFoldersSection.addLabel));
      await tester.pumpAndSettle();
      expect(p.localFolders, ['/home/me/Films']);
      expect(source.scans, 1);
      expect(find.text('/home/me/Films'), findsOneWidget);
      expect(find.text('1 video found'), findsOneWidget);

      // The same folder again, and a dialog closed: nothing changes.
      await tester.tap(find.text(LocalFoldersSection.addLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text(LocalFoldersSection.addLabel));
      await tester.pumpAndSettle();
      expect(p.localFolders, ['/home/me/Films']);
      expect(source.scans, 1);

      source.files = [];
      await tester.tap(find.byTooltip(LocalFoldersSection.removeTooltip));
      await tester.pumpAndSettle();
      expect(p.localFolders, isEmpty);
      expect(source.scans, 2);
      expect(media.files.entries, isEmpty);
      expect(find.text('/home/me/Films'), findsNothing);
    });

    test('the scan line counts in words a person says', () {
      expect(
        LocalFoldersSection.statusLine(scanning: true, found: 3),
        'Looking for videos…',
      );
      expect(
        LocalFoldersSection.statusLine(scanning: false, found: 1),
        '1 video found',
      );
      expect(
        LocalFoldersSection.statusLine(scanning: false, found: 0),
        '0 videos found',
      );
    });
  });
}

class _ThrowingSource implements LocalMediaSource {
  @override
  String get setupTitle => '';

  @override
  String get setupDetail => '';

  @override
  Future<LocalMediaAccess> access() => throw PlatformException(code: 'x');

  @override
  Future<LocalMediaAccess> requestAccess() =>
      throw PlatformException(code: 'x');

  @override
  Future<List<LocalMediaFacts>> scan() => throw PlatformException(code: 'x');

  @override
  Future<Uint8List?> thumbnail(String uri, {required int size}) =>
      throw PlatformException(code: 'x');
}
