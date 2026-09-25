import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

final DateTime _first = DateTime.utc(2026, 9, 20, 9);
final DateTime _later = DateTime.utc(2026, 9, 25, 12);

LinkedDriveFile _file({
  String id = 'drive-file-1',
  String name = 'one.mkv',
  String mime = 'video/x-matroska',
  DateTime? at,
  String? cinemetaId,
}) => LinkedDriveFile(
  fileId: id,
  name: name,
  mimeType: mime,
  linkedAt: at ?? _first,
  cinemetaId: cinemetaId,
);

void main() {
  test('a row round-trips through the preferences file', () {
    final file = _file(cinemetaId: 'tt2543164');

    expect(LinkedDriveFile.fromJson(file.toJson()), file);
  });

  test('the Cinemeta id is written only when there is one', () {
    expect(_file().toJson().containsKey('cinemeta'), isFalse);
    expect(_file(cinemetaId: 'tt2543164').toJson()['cinemeta'], 'tt2543164');
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
        .linking(_file(name: 'one.mkv', cinemetaId: 'tt2543164'))
        .linking(_file(name: 'renamed.mkv', at: _later));

    final row = files.entries.single;
    expect(row.linkedAt, _first, reason: 'it has been reachable since then');
    expect(row.name, 'renamed.mkv', reason: 'what Drive calls it now');
    // A second pairing knows no more about the title than the first did, so
    // a match already made is not thrown away by re-picking the file.
    expect(row.cinemetaId, 'tt2543164');
  });

  test('a Cinemeta id can be set, cleared, and asked for by file', () {
    final files = LinkedDriveFiles.empty.linking(_file());

    final matched = files.withCinemetaId('drive-file-1', 'tt2543164');
    expect(matched.forFile('drive-file-1')!.cinemetaId, 'tt2543164');
    expect(
      matched.withCinemetaId('drive-file-1', null).entries.single.cinemetaId,
      isNull,
    );
    // A file nothing has linked is not added by writing an id against it.
    expect(files.withCinemetaId('nothing', 'tt0000000'), same(files));
    expect(files.forFile('nothing'), isNull);
  });
}
