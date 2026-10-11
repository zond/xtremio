import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/fake_prefs_client.dart';

DateTime _at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

void main() {
  group('Faces', () {
    test('a mark is the newest face, and clearing is a mark too', () {
      var faces = Faces.empty.marking('tt1', Face.like, _at(10));
      expect(faces.of('tt1'), Face.like);
      faces = faces.marking('tt1', Face.dislike, _at(20));
      expect(faces.of('tt1'), Face.dislike);
      faces = faces.marking('tt1', null, _at(30));
      expect(faces.of('tt1'), isNull);
      expect(faces.marks['tt1'], const FaceMark(null, 30));
    });

    test('merging keeps the newer mark per title, this side on a tie', () {
      final device = Faces({
        'tt1': const FaceMark(Face.like, 100),
        'tt2': const FaceMark(Face.dislike, 100),
        'tt3': const FaceMark(Face.like, 50),
      });
      final account = Faces({
        'tt1': const FaceMark(null, 200),
        'tt2': const FaceMark(Face.like, 100),
        'tt4': const FaceMark(Face.dismissed, 10),
      });
      final merged = device.merged(account);
      expect(merged.marks, {
        'tt1': const FaceMark(null, 200),
        'tt2': const FaceMark(Face.dislike, 100),
        'tt3': const FaceMark(Face.like, 50),
        'tt4': const FaceMark(Face.dismissed, 10),
      });
    });

    test('a forgetting drops every mark at or before it, wherever it is', () {
      final device = Faces({
        'tt1': const FaceMark(Face.like, 100),
        'tt2': const FaceMark(Face.like, 300),
      });
      final account = Faces(const {}, clearedAt: 100);
      final merged = device.merged(account);
      expect(merged.marks, {'tt2': const FaceMark(Face.like, 300)});
      expect(merged.clearedAt, 100);
      expect(account.merged(device), merged);
    });

    test('reads back what it writes, and drops rows it cannot read', () {
      final faces = Faces({
        'tt1': const FaceMark(Face.like, 1),
        'tt2': const FaceMark(Face.dislike, 2),
        'tt3': const FaceMark(Face.dismissed, 3),
        'tt4': const FaceMark(null, 4),
      }, clearedAt: 0);
      expect(Faces.fromJson(faces.toJson()), faces);
      expect(
        Faces.fromJson({
          'faces': {
            'tt1': {'kind': 'love', 'at': 1},
            'tt2': {'kind': 'like', 'at': '2'},
            'tt3': {'kind': 'like', 'at': 3},
          },
          'clearedAt': 'x',
        }),
        Faces({'tt3': const FaceMark(Face.like, 3)}),
      );
      expect(Faces.fromJson('nonsense'), Faces.empty);
    });

    test('keeps the newest Faces.limit marks and no more', () {
      var faces = Faces.empty;
      for (var i = 0; i <= Faces.limit; i++) {
        faces = faces.marking('tt$i', Face.like, _at(i + 1));
      }
      expect(faces.marks, hasLength(Faces.limit));
      expect(faces.marks.containsKey('tt0'), isFalse);
      expect(faces.marks.containsKey('tt${Faces.limit}'), isTrue);
    });

    test('ids with a face', () {
      final faces = Faces({
        'a': const FaceMark(Face.like, 1),
        'b': const FaceMark(Face.dislike, 1),
        'c': const FaceMark(Face.dislike, 1),
        'd': const FaceMark(null, 1),
      });
      expect(faces.idsWith(Face.dislike), {'b', 'c'});
      expect(faces.idsWith(Face.dismissed), isEmpty);
    });
  });

  test('the preferences keep the faces across a restart', () async {
    final client = FakePrefsClient();
    final prefs = AppPrefs(client: client);
    await prefs.load();
    final faces = Faces.empty.marking('tt1', Face.like, _at(5));
    await prefs.setFaces(faces);
    final again = AppPrefs(client: client);
    await again.load();
    expect(again.faces, faces);
    await prefs.setFaces(Faces.empty);
    expect(client.stored.containsKey(AppPrefs.facesKey), isFalse);
  });
}
