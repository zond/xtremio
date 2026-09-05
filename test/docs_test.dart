import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The reference walls live in `docs/` and `ANDROID.md` now, and the README is
/// a map to them. A wall nobody can find is worse than a wall, so these tests
/// hold the two things that make the split work: every link between the
/// documents resolves, and the README stays short enough to be read on
/// arrival.
///
/// They read the repository's own files, so they run from the package root the
/// way `flutter test` does.
void main() {
  group('the documents', () {
    // Everything a reader is meant to land on. The vendored READMEs under
    // `rust_builder/` and `build/` are somebody else's and are left alone.
    final docs = <File>[
      File('README.md'),
      File('AGENTS.md'),
      File('ANDROID.md'),
      ...Directory('docs')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.md')),
    ];

    test('every one of them exists', () {
      for (final doc in docs) {
        expect(doc.existsSync(), isTrue, reason: '${doc.path} is missing');
      }
      // The map names these; a rename that forgets one is the failure mode.
      for (final named in const [
        'docs/STATUS.md',
        'docs/ARCHITECTURE.md',
        'docs/OPERATIONS.md',
        'docs/CASTING.md',
        'docs/ADDONS.md',
        'docs/DEEP_LINKS.md',
        'ANDROID.md',
      ]) {
        expect(File(named).existsSync(), isTrue, reason: '$named is missing');
      }
    });

    test('the README fits on arrival', () {
      // It was 1637 lines, of which 1008 were architecture. What is left is
      // what xtremio is, the map, goals and parity, installing an addon,
      // platform support, getting started and the licence. Anything that
      // pushes it back past a couple of hundred lines belongs in a document
      // the map names instead.
      final lines = File('README.md').readAsLinesSync().length;
      expect(lines, lessThan(220), reason: 'README.md is $lines lines');
    });

    test('every link between them resolves', () {
      final broken = <String>[];
      for (final doc in docs) {
        final text = doc.readAsStringSync();
        for (final match in _link.allMatches(text)) {
          final target = match.group(1)!.trim();
          if (target.isEmpty || _external.hasMatch(target)) continue;
          final hash = target.indexOf('#');
          final path = hash < 0 ? target : target.substring(0, hash);
          final anchor = hash < 0 ? '' : target.substring(hash + 1);

          // Relative to the document holding the link, which is what a
          // reader's browser does with it.
          final file = path.isEmpty
              ? doc
              : File(Uri.directory(doc.parent.path).resolve(path).toFilePath());
          if (!file.existsSync()) {
            broken.add('${doc.path}: $target (no such file)');
            continue;
          }
          // Anchors only mean something in a document we can read; a link
          // into an asset or the licence is a file link and nothing more.
          if (anchor.isEmpty || !file.path.endsWith('.md')) continue;
          if (!_headings(file.readAsStringSync()).contains(anchor)) {
            broken.add('${doc.path}: $target (no such heading)');
          }
        }
      }
      expect(broken, isEmpty, reason: broken.join('\n'));
    });
  });
}

/// `[text](target)` and `![alt](target)`, which is every link these documents
/// use; none of them uses a reference-style one.
final _link = RegExp(r'\]\(([^)\s]+)\)');

final _external = RegExp(r'^(https?:|mailto:)');

/// GitHub's own heading slugs: lower-cased, formatting and punctuation
/// dropped, spaces hyphenated. Headings inside a fenced block are shell
/// comments, not headings, so the fences are tracked.
Set<String> _headings(String markdown) {
  final slugs = <String>{};
  var fenced = false;
  for (final line in const LineSplitter().convert(markdown)) {
    if (line.startsWith('```')) {
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    final heading = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(line);
    if (heading == null) continue;
    final slug = heading
        .group(1)!
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 \-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '-');
    slugs.add(slug);
  }
  return slugs;
}
