import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/stream_facts.dart';
import 'package:xtremio/features/drive/drive_match.dart';
import 'package:xtremio/features/drive/linked_files.dart';
import 'package:xtremio/features/similar/similar_resolver.dart';

import '../support/fake_prefs_client.dart';
import '../support/fake_secret_store.dart';

/// What a Drive filename is read as, and which catalogue answers are
/// accepted as being it.
///
/// **The subject is the refusals.** A missing poster costs nothing; a real
/// poster for the wrong film is a claim about somebody's file that nothing
/// on screen contradicts, so most of what is asserted here is an answer that
/// was *not* taken.
void main() {
  /// A Cinemeta meta, in the shape `catalog/{type}/top/search=…` answers
  /// with: `name`, `releaseInfo` and an id.
  Map<String, dynamic> meta(
    String name, {
    String id = 'tt0133093',
    Object? releaseInfo,
    String? type,
  }) => {
    'id': id,
    'imdb_id': id,
    'name': name,
    'releaseInfo': ?releaseInfo,
    'type': ?type,
  };

  /// A search that answers [metas] for anything, and records what it was
  /// asked.
  ({CatalogueSearch search, List<String> asked}) answering(
    List<Map<String, dynamic>> metas,
  ) {
    final asked = <String>[];
    return (
      search: (type, query) async {
        asked.add('$type/$query');
        return metas;
      },
      asked: asked,
    );
  }

  group('what a name says it is', () {
    test('a film is a title and a year, with the rest of the name dropped', () {
      final read = ReleaseIdentity.ofName(
        'The.Matrix.1999.RERIP.2160p.UHD.BluRay.X265-IAMABLE.mkv',
      );

      expect(read.title, 'The Matrix');
      expect(read.year, 1999);
      expect(read.isEpisode, isFalse);
      expect(read.season, isNull);
    });

    test('an episode is a title and two numbers, from the name alone', () {
      final read = ReleaseIdentity.ofName(
        'Breaking.Bad.S01E01.1080p.BluRay.x265-KONTRAST.mkv',
      );

      expect(read.title, 'Breaking Bad');
      expect(read.season, 1);
      expect(read.episode, 1);
      expect(read.isEpisode, isTrue);
      expect(read.year, isNull, reason: 'the name gave none');
    });

    test('a pack names a season and no episode within it', () {
      final read = ReleaseIdentity.ofName('30.Rock.S02.1080p.BluRay.x265.mkv');

      expect(read.season, 2);
      expect(read.episode, isNull);
      expect(read.isEpisode, isFalse, reason: 'it names no one video');
    });

    test('separators are folded, so three spellings read the same', () {
      for (final spelling in [
        'The.Matrix.1999.1080p.mkv',
        'The Matrix (1999) 1080p.mkv',
        'The_Matrix_1999_1080p.mkv',
      ]) {
        final read = ReleaseIdentity.ofName(spelling);
        expect(read.title, 'The Matrix', reason: spelling);
        expect(read.year, 1999, reason: spelling);
      }
    });

    test('a directory in front and a container on the end are not the '
        'title', () {
      final read = ReleaseIdentity.ofName('Season 2/30.Rock.S02E11.1080p.mkv');

      expect(read.title, '30 Rock');
      expect(read.season, 2);
      expect(read.episode, 11);
    });

    test('`1x01` is the other spelling of the same thing', () {
      final read = ReleaseIdentity.ofName('Fawlty Towers 1x03.avi');

      expect(read.title, 'Fawlty Towers');
      expect(read.season, 1);
      expect(read.episode, 3);
    });

    test('a name of nothing but how it looks has no title at all', () {
      expect(ReleaseIdentity.ofName('1080p.x265.mkv').hasNoTitle, isTrue);
      expect(ReleaseIdentity.ofName('.mkv').hasNoTitle, isTrue);
    });

    test('the two names the note above the list shows do parse', () {
      // The note tells a viewer to name their files like these, so this is
      // the note's own claim under test: change the parser and find out here
      // rather than on a television.
      final film = ReleaseIdentity.ofName(
        LinkedDriveFilesView.nameExamples.first,
      );
      expect(film.title, 'The Matrix');
      expect(film.year, 1999);
      final episode = ReleaseIdentity.ofName(
        LinkedDriveFilesView.nameExamples.last,
      );
      expect(episode.title, 'Breaking Bad');
      expect(episode.season, 2);
      expect(episode.episode, 11);
    });
  });

  group('which catalogue is asked', () {
    test(
      'a name with an episode marker is a series, and only a series',
      () async {
        final fake = answering([]);
        await matchDriveFile(
          'Breaking.Bad.S01E01.1080p.mkv',
          search: fake.search,
        );

        expect(fake.asked, ['series/Breaking Bad']);
      },
    );

    test('a name without one is a film, and only a film', () async {
      final fake = answering([]);
      await matchDriveFile('The.Matrix.1999.1080p.mkv', search: fake.search);

      expect(fake.asked, ['movie/The Matrix']);
    });

    test('a name with no title is not searched for at all', () async {
      final fake = answering([]);

      expect(
        await matchDriveFile('1080p.x265.mkv', search: fake.search),
        isNull,
      );
      expect(fake.asked, isEmpty, reason: 'nothing to ask about');
    });
  });

  group('which answer is accepted', () {
    test('the title and the year agreeing is a match', () async {
      final match = await matchDriveFile(
        'The.Matrix.1999.1080p.BluRay.mkv',
        search: answering([
          meta('The Matrix Reloaded', id: 'tt0234215', releaseInfo: '2003'),
          meta('The Matrix', releaseInfo: '1999', type: 'movie'),
        ]).search,
      );

      expect(match, isNotNull);
      expect(match!.cinemetaId, 'tt0133093');
      expect(match.type, 'movie');
      expect(match.name, 'The Matrix');
      expect(match.year, 1999);
    });

    test('a year one out either way is the same film', () async {
      final match = await matchDriveFile(
        'The.Matrix.2000.1080p.mkv',
        search: answering([meta('The Matrix', releaseInfo: '1999')]).search,
      );

      expect(match?.year, 1999, reason: 'festival and territory dates differ');
    });

    test('two years out is a different film', () async {
      expect(
        await matchDriveFile(
          'The.Matrix.2002.1080p.mkv',
          search: answering([meta('The Matrix', releaseInfo: '1999')]).search,
        ),
        isNull,
      );
    });

    test('a title that is only nearly the same is not the same', () async {
      expect(
        await matchDriveFile(
          'The.Matricks.1999.mkv',
          search: answering([meta('The Matrix', releaseInfo: '1999')]).search,
        ),
        isNull,
      );
    });

    test('case, punctuation and a leading article are not what anybody gets '
        'wrong', () async {
      final match = await matchDriveFile(
        'the-matrix-1999.mkv',
        search: answering([meta('The Matrix', releaseInfo: '1999')]).search,
      );

      expect(match?.cinemetaId, 'tt0133093');
    });

    test(
      'with no year in the name, one answer is taken and two are not',
      () async {
        // This is the guard that stops `The Office` becoming a coin toss
        // between the American series and the British one.
        final one = await matchDriveFile(
          'Breaking.Bad.S01E01.mkv',
          search: answering([
            meta('Breaking Bad', id: 'tt0903747', releaseInfo: '2008-2013'),
          ]).search,
        );
        expect(one?.cinemetaId, 'tt0903747');
        expect(one?.season, 1);
        expect(one?.episode, 1);
        expect(one?.videoId, 'tt0903747:1:1');

        final two = await matchDriveFile(
          'The.Office.S01E01.mkv',
          search: answering([
            meta('The Office', id: 'tt0386676', releaseInfo: '2005-2013'),
            meta('The Office', id: 'tt0290978', releaseInfo: '2001-2003'),
          ]).search,
        );
        expect(two, isNull, reason: 'nothing in the name tells them apart');
      },
    );

    test('a name that is not a title matches nothing, because nothing is '
        'called that', () async {
      // `ep6.avi` is refused by the answer having to *be* it, not by a list
      // of words that look like titles.
      expect(
        await matchDriveFile(
          'ep6.avi',
          search: answering([
            meta('Episode 6', id: 'tt1234567', releaseInfo: '2011'),
          ]).search,
        ),
        isNull,
      );
    });

    test('an answer with no id is not an answer', () async {
      expect(
        await matchDriveFile(
          'The.Matrix.1999.mkv',
          search: answering([
            {'name': 'The Matrix', 'releaseInfo': '1999'},
          ]).search,
        ),
        isNull,
      );
    });

    test(
      'a search that throws is a file with no match, not an error',
      () async {
        expect(
          await matchDriveFile(
            'The.Matrix.1999.mkv',
            search: (type, query) async => throw StateError('no network'),
          ),
          isNull,
        );
      },
    );

    test('the type Cinemeta names wins over the one that was asked for', () {
      final match = acceptMatch(
        [meta('The Matrix', releaseInfo: '1999', type: 'movie')],
        ReleaseIdentity.ofName('The.Matrix.1999.mkv'),
        type: 'movie',
      );

      expect(match?.type, 'movie');
    });
  });

  group('a pass over the linked files', () {
    Future<DriveAccount> account({List<String> names = const []}) async {
      final prefs = AppPrefs(client: FakePrefsClient());
      await prefs.load();
      final drive = DriveAccount(prefs: prefs, secrets: FakeSecretStore());
      await drive.load();
      addTearDown(() {
        drive.dispose();
        prefs.dispose();
      });
      for (final (index, name) in names.indexed) {
        await drive.linkFile(
          refreshToken: 'token',
          fileId: 'drive-file-$index',
          name: name,
          mimeType: 'video/x-matroska',
        );
      }
      return drive;
    }

    test('a match is written down once and never asked for again', () async {
      final drive = await account(names: ['The.Matrix.1999.1080p.mkv']);
      final fake = answering([meta('The Matrix', releaseInfo: '1999')]);
      final run = DriveMatchRun(account: drive, search: fake.search);

      await run.run();
      expect(drive.files.entries.single.match?.cinemetaId, 'tt0133093');
      expect(fake.asked, hasLength(1));

      // Every later pass, for the life of the run and of the stored list.
      await run.run();
      await DriveMatchRun(account: drive, search: fake.search).run();
      expect(
        fake.asked,
        hasLength(1),
        reason: 'the stored match is what keeps it from being searched twice',
      );
    });

    test('a file nothing matched is asked about once a run, and again under a '
        'better name', () async {
      final drive = await account(names: ['ep6.avi']);
      final fake = answering([]);
      final run = DriveMatchRun(account: drive, search: fake.search);

      await run.run();
      await run.run();
      expect(drive.files.entries.single.match, isNull);
      expect(
        fake.asked,
        hasLength(1),
        reason: 'nothing is stored for a miss, so the run has to remember',
      );

      // The one thing a viewer can do about it: rename it in Drive and link
      // it again. The note above the list says so, so it has to work here.
      await drive.linkFile(
        refreshToken: 'token',
        fileId: 'drive-file-0',
        name: 'The.Matrix.1999.mkv',
        mimeType: 'video/x-matroska',
      );
      await run.run();
      expect(fake.asked, hasLength(2));
      expect(fake.asked.last, 'movie/The Matrix');
    });

    test(
      'a pass started while one is in flight asks about nothing twice',
      () async {
        // The list starts a pass on every rebuild, so two are routinely in
        // flight at once. A file is claimed before the ask, so the second pass
        // steps over what the first one took -- and picks up what arrived
        // since, which a "one pass at a time" flag would have made it skip.
        final drive = await account(names: ['The.Matrix.1999.mkv']);
        final asked = <String>[];
        final held = Completer<void>();
        final run = DriveMatchRun(
          account: drive,
          search: (type, query) async {
            asked.add('$type/$query');
            await held.future;
            return const [];
          },
        );

        final first = run.run();
        await run.run();
        expect(asked, ['movie/The Matrix'], reason: 'claimed before the await');

        await drive.linkFile(
          refreshToken: 'token',
          fileId: 'drive-file-9',
          name: 'Arrival.2016.mkv',
          mimeType: 'video/x-matroska',
        );
        final third = run.run();
        held.complete();
        await Future.wait([first, third]);
        expect(asked, ['movie/The Matrix', 'movie/Arrival']);
      },
    );

    test('a file with no name at all is not searched for', () async {
      // Not a guard of its own: an empty name has no title in it, and a name
      // with no title is what [matchDriveFile] refuses before it asks.
      final drive = await account(names: ['']);
      final fake = answering([]);

      await DriveMatchRun(account: drive, search: fake.search).run();

      expect(fake.asked, isEmpty);
    });

    test('a pass covers every file that has no match', () async {
      final drive = await account(
        names: ['The.Matrix.1999.mkv', 'ep6.avi', 'Breaking.Bad.S01E01.mkv'],
      );
      final asked = <String>[];

      await DriveMatchRun(
        account: drive,
        search: (type, query) async {
          asked.add('$type/$query');
          return const [];
        },
      ).run();

      expect(asked, [
        'series/Breaking Bad',
        'movie/ep6',
        'movie/The Matrix',
      ], reason: 'most recently linked first, which is the list order');
    });
  });
}
