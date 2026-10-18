import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// `tool/rendition_slots.py`, which `tool/rendition-fetch` and
/// `tool/rendition-check` read a rendition's slots with, run on headers
/// built here the way stream-server's `layout.rs` writes them.

Uint8List box(String type, List<int> body) {
  final out = BytesBuilder()
    ..add(_u32(8 + body.length))
    ..add(ascii.encode(type))
    ..add(body);
  return out.toBytes();
}

List<int> _u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();
List<int> _u64(int v) => (ByteData(8)..setUint64(0, v)).buffer.asUint8List();
List<int> _u16(int v) => (ByteData(2)..setUint16(0, v)).buffer.asUint8List();

/// A version 1 `sidx` for track 1 at 90 kHz: [refs] are (size, duration,
/// starts with a SAP).
Uint8List sidx(
  List<(int, int, bool)> refs, {
  int earliest = 3600,
  int firstOffset = 0,
}) => box('sidx', [
  1, 0, 0, 0, // version 1, no flags
  ..._u32(1),
  ..._u32(90000),
  ..._u64(earliest),
  ..._u64(firstOffset),
  ..._u16(0),
  ..._u16(refs.length),
  for (final (size, duration, sap) in refs) ...[
    ..._u32(size),
    ..._u32(duration),
    ..._u32(sap ? 1 << 31 : 0),
  ],
]);

/// Two references a slot, as a rendition's video `sidx` has them.
const twoSlots = [
  (100, 90000, true),
  (900, 0, false),
  (100, 45000, true),
  (1948, 0, false),
];

final ftyp = box('ftyp', ascii.encode('isom\x00\x00\x02\x00'));
final moov = box('moov', const []);

/// Slot 0's first box, so the header visibly ends.
final styp = box('styp', ascii.encode('msdh'));

Future<ProcessResult> slots(Directory dir, List<int> file, List<String> args) {
  final path = '${dir.path}/rendition.mp4';
  File(path).writeAsBytesSync(file);
  return Process.run('python3', [
    '-I',
    'tool/rendition_slots.py',
    args.first,
    path,
    ...args.skip(1),
  ]);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('rendition-slots'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'a slot begins at each reference with a SAP, after the header',
    () async {
      final file = [...ftyp, ...moov, ...sidx(twoSlots), ...styp];
      final header = ftyp.length + moov.length + 40 + 12 * 4;

      final len = await slots(dir, file, ['header-len']);
      final listed = await slots(dir, file, ['list', '--json']);
      final offset = await slots(dir, file, ['offset', '1']);

      expect(len.stdout, '$header\n');
      expect(jsonDecode(listed.stdout as String), [
        {'index': 0, 'offset': header, 'size': 1000, 'start': 0.04},
        {'index': 1, 'offset': header + 1000, 'size': 2048, 'start': 1.04},
      ]);
      expect(offset.stdout, '${header + 1000}\n');
      expect(offset.exitCode, 0);
    },
  );

  test('the video sidx skips the sound sidx after it', () async {
    final sound = sidx(twoSlots, earliest: 0);
    final file = [
      ...ftyp,
      ...moov,
      ...sidx(twoSlots, firstOffset: sound.length),
      ...sound,
      ...styp,
    ];
    final header = ftyp.length + moov.length + 2 * (40 + 12 * 4);

    final listed = await slots(dir, file, ['list', '--json']);

    expect(listed.exitCode, 0, reason: '${listed.stderr}');
    expect(
      [
        for (final s in jsonDecode(listed.stdout as String) as List)
          s['offset'],
      ],
      [header, header + 1000],
    );
  });

  test('a file cut inside the header says how much it needs', () async {
    final whole = [...ftyp, ...moov, ...sidx(twoSlots), ...styp];

    final cut = await slots(dir, whole.sublist(0, 40), ['header-len']);

    expect(cut.exitCode, 2);
    expect(int.parse((cut.stdout as String).trim()), greaterThan(40));
    expect(
      int.parse((cut.stdout as String).trim()),
      lessThanOrEqualTo(whole.length),
    );
  });

  test('no slot k past the last, and no sidx is not a rendition', () async {
    final file = [...ftyp, ...moov, ...sidx(twoSlots), ...styp];

    final past = await slots(dir, file, ['offset', '2']);
    final plain = await slots(dir, [...ftyp, ...moov, ...styp], ['list']);

    expect(past.exitCode, 1);
    expect(past.stderr, 'no slot 2: the file has 2\n');
    expect(plain.exitCode, 1);
    expect(plain.stderr, 'not a rendition: the header has no sidx\n');
  });
}
