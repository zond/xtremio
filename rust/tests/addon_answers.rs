//! What the runtime-event pump makes of a board that has answered.
//!
//! The pump reads the model on every `NewState` and turns it into sweeps
//! for the addon-health record; these drive that reading directly, against
//! a model built by hand and an [`AppState`] of this test's own, so no
//! network, no runtime and no process globals are involved.

use serde_json::json;
use stremio_core::models::catalogs_with_extra::{CatalogsWithExtra, Selected};
use stremio_core::models::common::{Loadable, ResourceError, ResourceLoadable};
use stremio_core::runtime::EnvError;
use stremio_core::types::addon::{ResourcePath, ResourceRequest};
use stremio_core::types::events::DismissedEventsBucket;
use stremio_core::types::library::LibraryBucket;
use stremio_core::types::notifications::NotificationsBucket;
use stremio_core::types::profile::Profile;
use stremio_core::types::resource::MetaItemPreview;
use stremio_core::types::search_history::SearchHistoryBucket;
use stremio_core::types::server_urls::ServerUrlsBucket;
use stremio_core::types::streams::StreamsBucket;
use url::Url;
use xtremio_core::addon_health::{key_for, table_in, Record, ResourceKind, Table};
use xtremio_core::env::XtremioEnv;
use xtremio_core::model::{XtremioModel, XtremioModelField};
use xtremio_core::state::AppState;

const CINEMETA: &str = "https://v3-cinemeta.strem.io/manifest.json";
const CHANNELS: &str = "https://v3-channels.strem.io/manifest.json";

fn url(url: &str) -> Url {
    Url::parse(url).expect("parse")
}

/// A model with nothing loaded; the tests put a board into it.
fn empty_model() -> XtremioModel {
    let profile = Profile::default();
    let uid = profile.uid();
    let (model, _effects) = XtremioModel::new(
        profile,
        LibraryBucket::new(uid.clone(), vec![]),
        StreamsBucket::new(uid.clone()),
        ServerUrlsBucket::new::<XtremioEnv>(uid.clone()),
        NotificationsBucket::new::<XtremioEnv>(uid.clone(), vec![]),
        SearchHistoryBucket::new(uid.clone()),
        DismissedEventsBucket::new(uid),
    );
    model
}

fn item() -> MetaItemPreview {
    serde_json::from_value(json!({ "id": "tt0063350", "type": "movie", "name": "A film" }))
        .expect("a meta preview")
}

/// One catalog row of the board: one addon, one page, one answer.
fn row(
    base: &str,
    content: Option<Loadable<Vec<MetaItemPreview>, ResourceError>>,
) -> Vec<ResourceLoadable<Vec<MetaItemPreview>>> {
    vec![ResourceLoadable {
        request: ResourceRequest::new(
            url(base),
            ResourcePath::without_extra("catalog", "movie", "top"),
        ),
        content,
    }]
}

/// A board of the given rows, as `ActionLoad::CatalogsWithExtra` leaves it.
fn board(rows: Vec<Vec<ResourceLoadable<Vec<MetaItemPreview>>>>) -> CatalogsWithExtra {
    CatalogsWithExtra {
        selected: Some(Selected {
            r#type: None,
            extra: vec![],
        }),
        catalogs: rows,
    }
}

/// The answer with content, the answer with nothing, and the two ways of
/// not answering at all.
fn answered() -> Option<Loadable<Vec<MetaItemPreview>, ResourceError>> {
    Some(Loadable::Ready(vec![item()]))
}

fn empty() -> Option<Loadable<Vec<MetaItemPreview>, ResourceError>> {
    Some(Loadable::Err(ResourceError::EmptyContent))
}

fn failed() -> Option<Loadable<Vec<MetaItemPreview>, ResourceError>> {
    Some(Loadable::Err(ResourceError::Env(EnvError::Fetch(
        "connection refused".to_owned(),
    ))))
}

fn loading() -> Option<Loadable<Vec<MetaItemPreview>, ResourceError>> {
    Some(Loadable::Loading)
}

fn observe(app: &AppState, model: &XtremioModel) -> usize {
    xtremio_core::addon_observer::observe(app, model, &[XtremioModelField::Board])
}

fn catalog_record(table: &Table, base: &str) -> Record {
    table
        .get(&key_for(&url(base)))
        .and_then(|kinds| kinds.get(&ResourceKind::Catalog))
        .cloned()
        .unwrap_or_else(|| {
            panic!(
                "no catalog record for {base}: {:?}",
                table.keys().collect::<Vec<_>>()
            )
        })
}

fn counts(record: &Record) -> (f64, f64, f64) {
    (record.ok, record.empty, record.fail)
}

#[test]
fn a_board_load_records_the_catalog_that_failed_and_the_one_that_worked() {
    let app = AppState::default();
    let mut model = empty_model();
    model.board = board(vec![row(CINEMETA, answered()), row(CHANNELS, failed())]);

    assert_eq!(observe(&app, &model), 1, "the load was one sweep");

    let table = table_in(&app);
    assert_eq!(table.len(), 2, "{:?}", table.keys().collect::<Vec<_>>());
    assert_eq!(counts(&catalog_record(&table, CINEMETA)), (1.0, 0.0, 0.0));
    assert_eq!(counts(&catalog_record(&table, CHANNELS)), (0.0, 0.0, 1.0));
    assert!(catalog_record(&table, CINEMETA).last_ok.is_some());
    assert!(catalog_record(&table, CHANNELS).last_fail.is_some());
}

#[test]
fn re_emitting_the_same_state_records_nothing_more() {
    let app = AppState::default();
    let mut model = empty_model();
    model.board = board(vec![row(CINEMETA, answered()), row(CHANNELS, failed())]);

    assert_eq!(observe(&app, &model), 1);
    let after_the_load = table_in(&app);

    // A `NewState` for the board arrives for anything that changes in it,
    // and the pump reads the whole field every time.
    for _ in 0..5 {
        assert_eq!(observe(&app, &model), 0, "a re-emitted state was counted");
    }
    assert_eq!(table_in(&app), after_the_load);
}

#[test]
fn a_board_where_every_catalog_failed_is_recorded_against_nobody() {
    let app = AppState::default();
    let mut model = empty_model();
    model.board = board(vec![row(CINEMETA, failed()), row(CHANNELS, failed())]);

    assert_eq!(
        observe(&app, &model),
        0,
        "an outage was recorded as evidence"
    );
    assert!(
        table_in(&app).is_empty(),
        "{:?}",
        table_in(&app).keys().collect::<Vec<_>>()
    );
}

/// The regression this whole "a sweep is a load" arrangement exists for:
/// stremio-core settles one answer per `NewState`, so counting each event
/// on its own would make every failure a sweep of one -- an all-failed
/// sweep -- and no failure would ever be recorded.
#[test]
fn a_failure_that_settles_after_the_others_is_still_part_of_their_load() {
    let app = AppState::default();
    let mut model = empty_model();

    model.board = board(vec![row(CINEMETA, answered()), row(CHANNELS, loading())]);
    assert_eq!(observe(&app, &model), 0, "the load was not finished");
    assert!(table_in(&app).is_empty(), "counted half a load");

    model.board = board(vec![row(CINEMETA, answered()), row(CHANNELS, failed())]);
    assert_eq!(observe(&app, &model), 1);

    let table = table_in(&app);
    assert_eq!(counts(&catalog_record(&table, CINEMETA)), (1.0, 0.0, 0.0));
    assert_eq!(counts(&catalog_record(&table, CHANNELS)), (0.0, 0.0, 1.0));
}

/// The Public Domain Movies case: a catalog that legitimately has nothing
/// for this request answered, and must not be counted as broken.
#[test]
fn a_catalog_with_nothing_in_it_answered() {
    let app = AppState::default();
    let mut model = empty_model();
    model.board = board(vec![row(CINEMETA, answered()), row(CHANNELS, empty())]);

    assert_eq!(observe(&app, &model), 1);

    let record = catalog_record(&table_in(&app), CHANNELS);
    assert_eq!(counts(&record), (0.0, 1.0, 0.0));
    assert_eq!(record.last_fail, None, "an empty answer moved last_fail");
    assert_eq!(
        record.last_ok, None,
        "an empty answer is not proof it works"
    );
}

/// A board row outside the range the app asked for is planned and never
/// requested. It is not an answer, and it does not keep the load open
/// either -- otherwise nothing below the fold would ever be recorded.
#[test]
fn a_row_nobody_scrolled_to_is_not_an_answer() {
    let app = AppState::default();
    let mut model = empty_model();
    model.board = board(vec![row(CINEMETA, answered()), row(CHANNELS, None)]);

    assert_eq!(observe(&app, &model), 1);

    let table = table_in(&app);
    assert_eq!(
        table.keys().collect::<Vec<_>>(),
        vec![key_for(&url(CINEMETA))]
    );
}

/// Asking again after the screen was unloaded is a new answer, because the
/// addon was asked again.
#[test]
fn a_board_that_was_unloaded_and_loaded_again_counts_again() {
    let app = AppState::default();
    let mut model = empty_model();
    model.board = board(vec![row(CINEMETA, answered()), row(CHANNELS, failed())]);
    assert_eq!(observe(&app, &model), 1);

    model.board = CatalogsWithExtra::default();
    assert_eq!(observe(&app, &model), 0, "an unload is not an answer");

    model.board = board(vec![row(CINEMETA, answered()), row(CHANNELS, failed())]);
    assert_eq!(observe(&app, &model), 1);

    let table = table_in(&app);
    assert_eq!(counts(&catalog_record(&table, CINEMETA)), (2.0, 0.0, 0.0));
    assert_eq!(counts(&catalog_record(&table, CHANNELS)), (0.0, 0.0, 2.0));
}
