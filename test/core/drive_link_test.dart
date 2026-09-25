import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

final DateTime _first = DateTime.utc(2026, 9, 20, 9);
final DateTime _later = DateTime.utc(2026, 9, 25, 12);

LinkedDriveFile _file({
  String id = 'drive-file-1',
  String name = 'one.mkv',
  String mime = 'video/x-matroska',
  DateTime? at,
  int? height,
  int? durationMillis,
  LinkedDriveMatch? match,
}) => LinkedDriveFile(
  fileId: id,
  name: name,
  mimeType: mime,
  linkedAt: at ?? _first,
  height: height,
  durationMillis: durationMillis,
  match: match,
);

/// A film's match, which is the shape with the fewest fields in it.
const LinkedDriveMatch _arrival = LinkedDriveMatch(
  cinemetaId: 'tt2543164',
  type: 'movie',
  name: 'Arrival',
  year: 2016,
);

/// An episode's: the same plus the two numbers the filename gave.
const LinkedDriveMatch _episode = LinkedDriveMatch(
  cinemetaId: 'tt0903747',
  type: 'series',
  name: 'Breaking Bad',
  year: 2008,
  season: 1,
  episode: 1,
);

void main() {
  test('a row round-trips through the preferences file', () {
    expect(
      LinkedDriveFile.fromJson(_file(match: _arrival).toJson()),
      _file(match: _arrival),
    );
    // The episode numbers are half of what a lookup asks for, so the trip
    // is made twice: a film has neither of them and a row that dropped them
    // would still round-trip.
    expect(
      LinkedDriveFile.fromJson(_file(match: _episode).toJson()),
      _file(match: _episode),
    );
  });

  test('what Drive measured round-trips, and a file it has not measured '
      'round-trips as a file nobody measured', () {
    // Both halves, because the absent one is the ordinary case: Drive fills
    // `videoMediaMetadata` in after it has processed an upload and leaves
    // it out for anything it did not decode.
    final measured = _file(height: 2160, durationMillis: 6960000);
    expect(LinkedDriveFile.fromJson(measured.toJson()), measured);
    expect(LinkedDriveFile.fromJson(measured.toJson())!.height, 2160);
    expect(
      LinkedDriveFile.fromJson(measured.toJson())!.durationMillis,
      6960000,
    );

    final unmeasured = _file();
    expect(unmeasured.height, isNull);
    expect(LinkedDriveFile.fromJson(unmeasured.toJson()), unmeasured);
  });

  test('a measurement is written only when there is one, so a row from '
      'before them reads back as a row nobody measured', () {
    expect(_file().toJson().containsKey('height'), isFalse);
    expect(_file().toJson().containsKey('durationMillis'), isFalse);
    expect(_file(height: 1080).toJson()['height'], 1080);

    // Exactly what a preferences file written by the build before this one
    // holds: the four keys that were there, and neither of the new ones.
    final stored = LinkedDriveFile.fromJson({
      'id': 'drive-file-1',
      'name': 'one.mkv',
      'mime': 'video/x-matroska',
      'linkedAt': _first.toIso8601String(),
    })!;
    expect(stored, _file());
    expect(stored.height, isNull);
    expect(stored.durationMillis, isNull);

    // And a value of a type this build cannot use is the same as none:
    // nothing downstream may be handed a height that is not a number.
    final odd = LinkedDriveFile.fromJson({
      'id': 'drive-file-1',
      'height': '1080',
      'durationMillis': 3.5,
    })!;
    expect(odd.height, isNull);
    expect(odd.durationMillis, isNull);
  });

  test('the match is written only when there is one', () {
    expect(_file().toJson().containsKey('match'), isFalse);
    expect(_file(match: _arrival).toJson()['match'], {
      'id': 'tt2543164',
      'type': 'movie',
      'name': 'Arrival',
      'year': 2016,
    });
  });

  test('half a match is no match: an id with no type, an episode with no '
      'season', () {
    // Both halves of the video id, or neither: a season with no episode
    // number is a claim about which video this is that names no video.
    expect(
      LinkedDriveMatch.fromJson({'id': 'tt0903747', 'type': 'series'}),
      isNotNull,
    );
    expect(LinkedDriveMatch.fromJson({'id': 'tt0903747'}), isNull);
    expect(LinkedDriveMatch.fromJson({'type': 'series'}), isNull);
    final halved = LinkedDriveMatch.fromJson({
      'id': 'tt0903747',
      'type': 'series',
      'season': 1,
    })!;
    expect(halved.season, isNull);
    expect(halved.isEpisode, isFalse);
  });

  test('a match answers the lookup a details screen makes', () {
    expect(_episode.videoId, 'tt0903747:1:1');
    expect(_arrival.videoId, isNull, reason: "a film's video is the film");
    expect(_episode.isFor('tt0903747', videoId: 'tt0903747:1:1'), isTrue);
    expect(_episode.isFor('tt0903747', videoId: 'tt0903747:1:2'), isFalse);
    expect(_episode.isFor('tt0903747'), isTrue, reason: 'the series, at all');
    expect(_arrival.isFor('tt2543164', videoId: 'tt2543164'), isTrue);
    expect(_arrival.isFor('tt0903747'), isFalse);
  });

  test('a row with no id is no row at all', () {
    expect(LinkedDriveFile.fromJson({'name': 'one.mkv'}), isNull);
    expect(LinkedDriveFile.fromJson({'id': '  '}), isNull);
    expect(LinkedDriveFile.fromJson('one.mkv'), isNull);
  });

  test('everything but the id has an answer for being missing', () {
    final file = LinkedDriveFile.fromJson({'id': 'drive-file-1'})!;

    expect(file.fileId, 'drive-file-1');
    expect(file.name, isEmpty);
    expect(file.mimeType, isEmpty);
    // Nobody knows when it was linked, said in a way that sorts oldest.
    expect(file.linkedAt, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    expect(file.cinemetaId, isNull);
  });

  test('a list read back drops only the rows it cannot read', () {
    final files = LinkedDriveFiles.fromJson([
      {'id': 'drive-file-1', 'name': 'one.mkv'},
      {'name': 'nameless'},
      42,
      {'id': 'drive-file-2', 'name': 'two.mkv'},
    ]);

    expect(files.entries.map((file) => file.fileId), [
      'drive-file-1',
      'drive-file-2',
    ]);
  });

  test('a stored value that is not a list is nothing linked', () {
    expect(LinkedDriveFiles.fromJson('drive-file-1'), LinkedDriveFiles.empty);
    expect(LinkedDriveFiles.fromJson(null), LinkedDriveFiles.empty);
    expect(LinkedDriveFiles.fromJson(const []), LinkedDriveFiles.empty);
  });

  test('linking puts the newest first', () {
    final files = LinkedDriveFiles.empty
        .linking(_file(id: 'drive-file-1'))
        .linking(_file(id: 'drive-file-2', at: _later));

    expect(files.entries.map((file) => file.fileId), [
      'drive-file-2',
      'drive-file-1',
    ]);
  });

  test('the same file picked twice keeps when it was first linked', () {
    final files = LinkedDriveFiles.empty
        .linking(_file(name: 'one.mkv', match: _arrival))
        .linking(_file(name: 'renamed.mkv', at: _later));

    final row = files.entries.single;
    expect(row.linkedAt, _first, reason: 'it has been reachable since then');
    expect(row.name, 'renamed.mkv', reason: 'what Drive calls it now');
    // A second pairing knows no more about the title than the first did, so
    // a match already made is not thrown away by re-picking the file.
    expect(row.cinemetaId, 'tt2543164');
  });

  test('and keeps what Drive measured, which a Picker never knows', () {
    // A pairing hands over a name and a mime type; `videoMediaMetadata`
    // comes from a listing. So re-picking a file must not blank the height
    // a reload had already written down.
    final files = LinkedDriveFiles.empty
        .linking(_file(height: 2160, durationMillis: 6960000))
        .linking(_file(name: 'renamed.mkv', at: _later));

    final row = files.entries.single;
    expect(row.height, 2160);
    expect(row.durationMillis, 6960000);
  });

  test('a match can be set, cleared, and asked for by file', () {
    final files = LinkedDriveFiles.empty.linking(_file());

    final matched = files.withMatch('drive-file-1', _arrival);
    expect(matched.forFile('drive-file-1')!.match, _arrival);
    expect(
      matched.withMatch('drive-file-1', null).entries.single.match,
      isNull,
    );
    // A file nothing has linked is not added by writing a match against it.
    expect(files.withMatch('nothing', _arrival), same(files));
    expect(files.forFile('nothing'), isNull);
  });

  test('the reverse lookup finds the files a meta id and a video id are', () {
    final files = LinkedDriveFiles.empty
        .linking(_file(id: 'drive-file-1', match: _arrival))
        .linking(_file(id: 'drive-file-2', match: _episode))
        .linking(_file(id: 'drive-file-3'));

    expect(
      files.matching('tt0903747', videoId: 'tt0903747:1:1').single.fileId,
      'drive-file-2',
    );
    expect(files.matching('tt0903747', videoId: 'tt0903747:1:2'), isEmpty);
    expect(files.matching('tt2543164').single.fileId, 'drive-file-1');
    // A file nothing matched is in no title's list, which is the whole
    // reason it needs a list of its own.
    expect(files.matching('tt0000000'), isEmpty);
  });

  test('a match knows where its poster is, from its id and not a stored '
      'string', () {
    // Written out rather than built from the id: a test that composes the
    // URL the way the code does passes at every URL.
    expect(
      _arrival.posterUrl,
      'https://images.metahub.space/poster/small/tt2543164/img',
    );
    expect(
      _episode.posterUrl,
      'https://images.metahub.space/poster/small/tt0903747/img',
    );
  });

  group('the matches the library has no card for', () {
    /// The three files the merge has to tell apart, newest linked first:
    /// an episode, a film, and a file nothing matched.
    final files = LinkedDriveFiles.empty
        .linking(_file(id: 'drive-file-3'))
        .linking(_file(id: 'drive-file-2', match: _arrival))
        .linking(_file(id: 'drive-file-1', match: _episode));

    test('is every matched one when the library holds none of them', () {
      expect(files.unlistedMatches(listed: const {}), [_episode, _arrival]);
    });

    test('is in link order, newest first', () {
      // The engine's items come first and these after, so the order here is
      // the only one they have. A linked file has never been watched, so
      // `lastwatched` has nothing to say about it.
      final older = LinkedDriveFiles.empty
          .linking(_file(id: 'drive-file-1', match: _episode))
          .linking(_file(id: 'drive-file-2', match: _arrival));
      expect(older.unlistedMatches(listed: const {}), [_arrival, _episode]);
    });

    test('drops a film whose card the engine already sent', () {
      expect(files.unlistedMatches(listed: const {'tt2543164'}), [_episode]);
    });

    test('drops an episode whose *show* the engine sent, because the card it '
        'belongs to is the show', () {
      expect(files.unlistedMatches(listed: const {'tt0903747'}), [_arrival]);
    });

    test('so a season linked into a library that already follows the show '
        'adds nothing at all', () {
      const second = LinkedDriveMatch(
        cinemetaId: 'tt0903747',
        type: 'series',
        name: 'Breaking Bad',
        year: 2008,
        season: 1,
        episode: 2,
      );
      const third = LinkedDriveMatch(
        cinemetaId: 'tt0903747',
        type: 'series',
        name: 'Breaking Bad',
        year: 2008,
        season: 1,
        episode: 3,
      );
      final season = LinkedDriveFiles.empty
          .linking(_file(id: 'drive-file-1', match: _episode))
          .linking(_file(id: 'drive-file-2', match: second))
          .linking(_file(id: 'drive-file-3', match: third));

      expect(season.unlistedMatches(listed: const {'tt0903747'}), isEmpty);
      // And with the show absent they are one card, not three: two files of
      // one title is one title.
      expect(season.unlistedMatches(listed: const {}), hasLength(1));
      expect(
        season.unlistedMatches(listed: const {}).single.cinemetaId,
        'tt0903747',
      );
    });

    test('is filtered by the type the engine has selected, and only by it', () {
      expect(files.unlistedMatches(listed: const {}, type: 'movie'), [
        _arrival,
      ]);
      expect(files.unlistedMatches(listed: const {}, type: 'series'), [
        _episode,
      ]);
      // Null is the engine's "All", and a type nothing matched is empty
      // rather than everything.
      expect(files.unlistedMatches(listed: const {}, type: null), hasLength(2));
      expect(files.unlistedMatches(listed: const {}, type: 'channel'), isEmpty);
    });

    test('never holds a file nothing matched: there is no card to add', () {
      // The Remote list is where an unmatched file lives, and the only
      // place it can: it has no title, so it has no card.
      final unmatched = LinkedDriveFiles.empty.linking(_file(id: 'ep6'));
      expect(unmatched.unlistedMatches(listed: const {}), isEmpty);
      expect(LinkedDriveFiles.empty.unlistedMatches(listed: const {}), isEmpty);
    });
  });
}
