import 'dart:convert';
import 'dart:io';

/// Model-field states recorded from the real core by the network tests in
/// `rust/tests/` (`cinemeta.rs`, `meta_details.rs`, `board.rs`).
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

/// `continue_watching_preview` after a minute of that movie was reported and
/// it was paused (rust/tests/meta_details.rs): one item, `timeOffset` 60 s
/// of a 96 min `duration`, `video_id` the movie itself.
Map<String, dynamic> loadContinueWatchingFixture() =>
    loadFixture('continue_watching_preview.json');

/// `board` over the default addons with `LoadRange {0, 2}` applied
/// (rust/tests/board.rs): six planned catalogs with labels, the first three
/// Ready (Cinemeta Popular movies/series, Featured movies), the rest with
/// `content: null`.
Map<String, dynamic> loadBoardFixture() =>
    loadFixture('board_default_addons.json');

/// `search` for "night of the living dead" over the default addons with
/// every row requested (rust/tests/board.rs): Cinemeta and Public Domain
/// Movies hits, YouTube rows failed with `Err Env`.
Map<String, dynamic> loadSearchFixture() =>
    loadFixture('search_default_addons.json');

/// `meta_details` for Breaking Bad (tt0903747) right after the guessing
/// load (rust/tests/meta_details.rs): Cinemeta meta with seasons 1-5 plus
/// specials, no `streamPath` (a series without `defaultVideoId` gets no
/// guess) and no streams.
Map<String, dynamic> loadSeriesMetaDetailsFixture() =>
    loadFixture('meta_details_series.json');

/// The same title after selecting S1E1 (`tt0903747:1:1`, "Pilot") with
/// `guessStream: false` and marking it watched: WatchHub answered
/// `EmptyContent`, the local addon failed with `Env`, `watchedVideoIds`
/// holds the episode.
Map<String, dynamic> loadSeriesEpisodeMetaDetailsFixture() =>
    loadFixture('meta_details_series_episode.json');
