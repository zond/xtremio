import 'dart:convert';
import 'dart:io';

/// Model-field states recorded from the real core by the network tests in
/// `rust/tests/` (`cinemeta.rs`, `meta_details.rs`).
Map<String, dynamic> loadFixture(String name) =>
    jsonDecode(File('rust/tests/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> loadDiscoverFixture() =>
    loadFixture('discover_cinemeta_top.json');

/// `meta_details` for Night of the Living Dead (tt0063350): Cinemeta meta,
/// WatchHub externals, a pubdomainmovies torrent, a failed local addon.
Map<String, dynamic> loadMetaDetailsFixture() =>
    loadFixture('meta_details_public_domain.json');

/// `player` after loading that torrent: `stream` resolved to the embedded
/// server's URL.
Map<String, dynamic> loadPlayerFixture() =>
    loadFixture('player_public_domain_torrent.json');
