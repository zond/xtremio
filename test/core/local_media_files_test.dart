import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_local_media_source.dart';
import '../support/fake_prefs_client.dart';

const LinkedDriveMatch _arrival = LinkedDriveMatch(
  cinemetaId: 'tt2543164',
  type: 'movie',
  name: 'Arrival',
  year: 2016,
);

const LinkedDriveMatch _pilot = LinkedDriveMatch(
  cinemetaId: 'tt0903747',
  type: 'series',
  name: 'Breaking Bad',
  year: 2008,
  season: 1,
  episode: 1,
);

/// The record of this device's videos: what a scan renews, what a match
/// fills in, and what the Library and details pages read.
void main() {
  const one = 'content://media/external/video/media/1';
  const two = 'content://media/external/video/media/2';

  group('a scan renews the record', () {
    test('a file found again keeps what was learnt about it', () {
      final before = LocalMediaFiles.empty
          .reconciled([localFacts(one, 'Arrival.2016.mkv')])
          .answering(one, _arrival);
      final after = before.reconciled([
        localFacts(one, 'Arrival.2016.mkv', height: 1080),
      ]);
      final file = after.forUri(one)!;
      expect(file.match, _arrival);
      expect(file.checked, isTrue);
      expect(file.height, 1080, reason: 'new facts are taken');
    });

    test('a renamed file is asked about again: the old answer was about '
        'the old name', () {
      final before = LocalMediaFiles.empty
          .reconciled([localFacts(one, 'Arrival.2016.mkv')])
          .answering(one, _arrival);
      final file = before
          .reconciled([localFacts(one, 'Breaking.Bad.S01E01.mkv')])
          .forUri(one)!;
      expect(file.match, isNull);
      expect(file.checked, isFalse);
    });

    test('a file not found again is gone, and one found twice is one', () {
      final before = LocalMediaFiles.empty.reconciled([
        localFacts(one, 'a.mkv'),
        localFacts(two, 'b.mkv'),
      ]);
      final after = before.reconciled([
        localFacts(two, 'b.mkv'),
        localFacts(two, 'b.mkv'),
      ]);
      expect([for (final file in after.entries) file.uri], [two]);
    });

    test('an answer of no match is still an answer: it is not asked '
        'again', () {
      final files = LocalMediaFiles.empty
          .reconciled([localFacts(one, 'holiday.mkv')])
          .answering(one, null);
      expect(files.forUri(one)!.checked, isTrue);
      expect(files.forUri(one)!.match, isNull);
    });
  });

  group('reading it', () {
    final files = LocalMediaFiles.empty
        .reconciled([
          localFacts(one, 'Arrival.2016.mkv'),
          localFacts(two, 'Breaking.Bad.S01E01.mkv'),
        ])
        .answering(one, _arrival)
        .answering(two, _pilot);

    test('a title finds its files, and an episode only its own', () {
      expect(files.matching('tt2543164').single.uri, one);
      expect(
        files.matching('tt0903747', videoId: 'tt0903747:1:1').single.uri,
        two,
      );
      expect(files.matching('tt0903747', videoId: 'tt0903747:1:2'), isEmpty);
    });

    test('the Library is given each title once, of the type asked, and '
        'none it already lists', () {
      expect(files.unlistedMatches(listed: const {}), [_arrival, _pilot]);
      expect(files.unlistedMatches(listed: const {}, type: 'movie'), [
        _arrival,
      ]);
      expect(files.unlistedMatches(listed: const {'tt2543164'}), [_pilot]);
    });
  });

  test('the record and the folders survive a restart', () async {
    final client = FakePrefsClient();
    final prefs = AppPrefs(client: client);
    addTearDown(prefs.dispose);
    await prefs.load();
    final files = LocalMediaFiles.empty
        .reconciled([localFacts(one, 'Arrival.2016.mkv', height: 2160)])
        .answering(one, _arrival);
    await prefs.setLocalMedia(files);
    await prefs.setLocalFolders(['/home/me/Films']);

    final again = AppPrefs(client: client);
    addTearDown(again.dispose);
    await again.load();
    expect(again.localMedia, files);
    expect(again.localFolders, ['/home/me/Films']);
  });

  test('a record entry with no address is dropped, not trusted', () {
    final files = LocalMediaFiles.fromJson([
      {'uri': '', 'name': 'x.mkv'},
      {'name': 'y.mkv'},
      {'uri': one, 'name': 'z.mkv'},
    ]);
    expect([for (final file in files.entries) file.name], ['z.mkv']);
  });
}
