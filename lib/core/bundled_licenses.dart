import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The licences a *compiled* Xtremio has to carry, added to the registry
/// Flutter's licence page reads.
///
/// The source in this repository is MIT, but a built binary embeds
/// `stream-server`, whose default build links `unrar-rs` so that a RAR
/// archive inside a torrent can be played. `unrar-rs` is GPL-3.0-or-later
/// and its licence says in as many words that redistributions **in binary
/// form must reproduce related license information from this file** -- the
/// unRAR restriction included. A licence text sitting in the repository
/// satisfies nothing there: what is distributed is the APK or the desktop
/// build, and this is how the text goes inside it.
///
/// `pubspec.yaml` ships both files as assets, and they are read only when
/// somebody opens the page: [LicenseRegistry.addLicense] takes a stream that
/// is not run until then, so this costs a boot nothing.
///
/// Flutter's own entries (every package in the graph) are registered by the
/// framework, so the page shows those beside these.
void registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const <String>[
      'unrar-rs (in stream-server, for RAR archives)',
    ], await rootBundle.loadString('LICENSE-unrar-rs'));
    yield LicenseEntryWithLineBreaks(const <String>[
      'Xtremio (compiled binaries)',
    ], await rootBundle.loadString('LICENSE-GPL-3.0'));
  });
}
