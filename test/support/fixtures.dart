import 'dart:convert';
import 'dart:io';

/// Model-field states recorded from the real core by the network tests in
/// `rust/tests/` (`cinemeta.rs`, `meta_details.rs`, `board.rs`,
/// `library_addons.rs`), plus the hand-authored `ctx_logged_in.json`.
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

/// `ctx` of a fresh anonymous profile (rust/tests/library_addons.rs): the
/// bundled official addons, default settings (`streamingServerUrl` is
/// stremio-core's loopback default; the recorder ran without the embedded
/// server), `auth: null`, empty notifications, `events` still loading.
Map<String, dynamic> loadCtxLoggedOutFixture() =>
    loadFixture('ctx_logged_out.json');

/// Hand-authored: the same profile with a fake account attached
/// (`user@example.com`, id `fake_user_id`, a placeholder auth key), modelled
/// on stremio-core's `unit_tests/ctx/authenticate.rs`. Never a real session.
Map<String, dynamic> loadCtxLoggedInFixture() =>
    loadFixture('ctx_logged_in.json');

/// `installed_addons` over the default profile with `{type: null}` loaded
/// (rust/tests/library_addons.rs): six official addons, types `null`,
/// movie, series, channel, other.
Map<String, dynamic> loadInstalledAddonsFixture() =>
    loadFixture('installed_addons_default.json');

/// `addon_details` for Cinemeta (rust/tests/library_addons.rs): installed
/// (`localAddon`) and its manifest fetched (`remoteAddon` Ready, protected
/// flag filled in from the official list).
Map<String, dynamic> loadAddonDetailsFixture() =>
    loadFixture('addon_details_cinemeta.json');

/// `remote_addons` for Cinemeta's `community` addon catalog of type `all`
/// (rust/tests/library_addons.rs), trimmed to 20 descriptors; the
/// selectable lists every catalog (Official, Community) and type.
Map<String, dynamic> loadRemoteAddonsFixture() =>
    loadFixture('remote_addons_community.json');

/// `library` with `{type: null, sort: lastwatched, page: 1}` loaded after a
/// movie (The Whisper Man, tt11561116) and a series (Lanterns, tt26545992)
/// were added through `AddToLibrary` (rust/tests/library_addons.rs): two
/// items with no progress, types `null`/movie/series, six sorts, no
/// `next_page`.
Map<String, dynamic> loadLibraryFixture() =>
    loadFixture('library_default.json');

/// What `downloads_list` answers, recorded hermetically by the `#[ignore]`d
/// `record_registry_fixture` in `rust/tests/downloads.rs`: three offline
/// downloads of two torrents it builds itself — a movie that finished
/// (`tt0063350:tt0063350`), an episode two thirds of the way through
/// (`tt0903747:tt0903747:1:1`) and one with nothing on disk yet
/// (`tt0903747:tt0903747:1:2`). The paths and the timestamps are fixed by
/// the recorder, so re-recording an unchanged registry changes no bytes and
/// the tests here can quote them.
Map<String, dynamic> loadDownloadsFixture() =>
    loadFixture('downloads_registry.json');
