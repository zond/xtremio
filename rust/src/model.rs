//! `XtremioModel`: the app model the stremio-core Runtime drives.
//!
//! A trimmed `WebModel`: the mandatory `ctx` plus one field per screen the
//! app renders (or is about to render). `#[derive(Model)]` generates `XtremioModelField` (a
//! `snake_case` serde enum, one variant per field) and the `update` /
//! `update_field` dispatch. Every field is serialized to JSON with serde for
//! the Dart side; there is no per-type mirroring -- with one exception, the
//! board and the search, whose items go over as the projection a poster
//! grid draws ([`GridItem`]).

use std::ops::{Deref, DerefMut};

use serde::Serialize;
use stremio_core::models::addon_details::AddonDetails;
use stremio_core::models::catalog_with_filters::CatalogWithFilters;
use stremio_core::models::catalogs_with_extra::{CatalogsWithExtra, Selected};
use stremio_core::models::common::{Loadable, ResourceLoadable};
use stremio_core::models::continue_watching_preview::ContinueWatchingPreview;
use stremio_core::models::ctx::Ctx;
use stremio_core::models::installed_addons_with_filters::InstalledAddonsWithFilters;
use stremio_core::models::library_with_filters::{LibraryWithFilters, NotRemovedFilter};
use stremio_core::models::meta_details::MetaDetails;
use stremio_core::models::player::Player;
use stremio_core::models::streaming_server::StreamingServer;
use stremio_core::runtime::msg::{Internal, Msg};
use stremio_core::runtime::{Effects, UpdateWithCtx};
use stremio_core::types::addon::Descriptor;
use stremio_core::types::events::DismissedEventsBucket;
use stremio_core::types::library::LibraryBucket;
use stremio_core::types::notifications::NotificationsBucket;
use stremio_core::types::profile::Profile;
use stremio_core::types::resource::{MetaItemPreview, PosterShape};
use stremio_core::types::search_history::SearchHistoryBucket;
use stremio_core::types::server_urls::ServerUrlsBucket;
use stremio_core::types::streams::StreamsBucket;
use stremio_core::Model;
use url::Url;

use crate::env::XtremioEnv;

#[derive(Model, Clone)]
#[model(XtremioEnv)]
pub struct XtremioModel {
    /// Profile, library, streams, server URLs, notifications, search history.
    pub ctx: Ctx,
    /// Continue watching row: library items with progress, newest first.
    /// Never loaded or unloaded; follows the library on its own.
    pub continue_watching_preview: ContinueWatchingPreview,
    /// Home: every catalog of every installed addon
    /// (`ActionLoad::CatalogsWithExtra`).
    pub board: GridCatalogs,
    /// Search results: every catalog supporting the `search` extra
    /// (`ActionLoad::CatalogsWithExtra` with `["search", query]`).
    pub search: GridCatalogs,
    /// One catalog with its filters (`ActionLoad::CatalogWithFilters`).
    pub discover: CatalogWithFilters<MetaItemPreview>,
    /// Meta + per-addon streams for one item (`ActionLoad::MetaDetails`).
    pub meta_details: MetaDetails,
    /// The embedded stream-server as the engine sees it (settings, base
    /// URL, torrent creation).
    pub streaming_server: StreamingServer,
    /// Playback state for the selected stream (`ActionLoad::Player`).
    pub player: Player,
    /// The library, filtered by type and sorted, everything not removed
    /// (`ActionLoad::LibraryWithFilters`). Follows the library on its own
    /// once loaded; `catalog` is cumulative across pages.
    pub library: LibraryWithFilters<NotRemovedFilter>,
    /// The profile's addons, filtered by type
    /// (`ActionLoad::InstalledAddonsWithFilters`); follows the profile.
    pub installed_addons: InstalledAddonsWithFilters,
    /// One `addon_catalog` (the community list) with its filters
    /// (`ActionLoad::CatalogWithFilters`, `Descriptor` items).
    pub remote_addons: CatalogWithFilters<Descriptor>,
    /// One addon by manifest URL: the installed copy and the fetched manifest
    /// (`ActionLoad::AddonDetails`).
    pub addon_details: AddonDetails,
}

/// A `CatalogsWithExtra` that does not follow the library.
///
/// stremio-core marks the model changed on every `LibraryChanged` -- a
/// pause, the progress push every 90 s under the player, a title kept --
/// because stremio-web merges each item's library flags into the board it
/// serializes, so there the board really has changed. Nothing this crate
/// puts on the wire for a board or a search reads the library
/// ([`GridItem`]), so here that `NewState` was a re-serialization of every
/// loaded catalog and a re-decode of the same document on the Dart UI
/// isolate, for a board nobody was looking at. The model itself is left
/// exactly as stremio-core keeps it: the arm being filtered changes no
/// state (`Effects::none()`), only the flag.
#[derive(Default, Clone)]
pub struct GridCatalogs(pub CatalogsWithExtra);

impl Deref for GridCatalogs {
    type Target = CatalogsWithExtra;

    fn deref(&self) -> &CatalogsWithExtra {
        &self.0
    }
}

impl DerefMut for GridCatalogs {
    fn deref_mut(&mut self) -> &mut CatalogsWithExtra {
        &mut self.0
    }
}

impl From<CatalogsWithExtra> for GridCatalogs {
    fn from(catalogs: CatalogsWithExtra) -> Self {
        GridCatalogs(catalogs)
    }
}

impl UpdateWithCtx<XtremioEnv> for GridCatalogs {
    fn update(&mut self, msg: &Msg, ctx: &Ctx) -> Effects {
        match msg {
            Msg::Internal(Internal::LibraryChanged(_)) => Effects::none().unchanged(),
            _ => UpdateWithCtx::<XtremioEnv>::update(&mut self.0, msg, ctx),
        }
    }
}

/// What a poster grid draws of one catalog item: the tile's id, type, name,
/// poster and shape, and the release year that sits beside the name.
///
/// A `MetaItemPreview` serializes to about 2 KB, of which `links` --
/// synthesized from the genres, the cast and the IMDb rating for a details
/// page this item never reaches -- is three fifths, and the description most
/// of the rest; a board of eight Cinemeta catalogs was 770 KB per pull,
/// pulled again as each row landed. The tile reads these six, so these six
/// cross. A tile's tap opens the details field by id and type, which
/// carries the whole item.
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct GridItem {
    id: String,
    r#type: String,
    name: String,
    poster: Option<Url>,
    poster_shape: PosterShape,
    release_info: Option<String>,
}

impl GridItem {
    fn of(item: &MetaItemPreview) -> GridItem {
        GridItem {
            id: item.id.clone(),
            r#type: item.r#type.clone(),
            name: item.name.clone(),
            poster: item.poster.clone(),
            poster_shape: item.poster_shape.clone(),
            release_info: item.release_info.clone(),
        }
    }
}

/// The name of one board/search row, aligned by index with `catalogs`.
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct CatalogLabel {
    name: String,
    addon_name: String,
    r#type: String,
}

/// A `CatalogsWithExtra` on the wire: the model's own `selected` and page
/// shape (`ResourceLoadable`/`Loadable`, so `content.type` is `Ready`,
/// `Loading` or `Err` exactly as stremio-core writes it), the items reduced
/// to [`GridItem`], plus `catalogLabels`. Owned, so it can be taken under
/// the model's read lock and serialized after it is released.
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct GridJson {
    selected: Option<Selected>,
    catalogs: Vec<Vec<ResourceLoadable<Vec<GridItem>>>>,
    catalog_labels: Vec<Option<CatalogLabel>>,
}

/// One model field as taken from the model, before it is a string.
///
/// The model sits behind a `std::sync::RwLock` whose readers queue behind a
/// waiting writer, and every dispatch and every addon answer is a writer.
/// Serializing under the read lock therefore parked the whole engine for
/// the length of the serialization, which for a loaded board was the
/// longest thing the lock ever saw. What is taken under the lock is now the
/// cheapest owned form of the field: a projection for the two grid fields,
/// the JSON itself for the small ones (where cloning the model would cost
/// more than writing it out).
#[derive(Debug)]
pub enum FieldSnapshot {
    /// Already serialized; the field is small enough that a clone would
    /// not have been cheaper.
    Json(String),
    /// A board or a search, still to be serialized.
    Grid(GridJson),
}

impl FieldSnapshot {
    /// The field as JSON.
    pub fn into_json(self) -> serde_json::Result<String> {
        match self {
            FieldSnapshot::Json(json) => Ok(json),
            FieldSnapshot::Grid(grid) => serde_json::to_string(&grid),
        }
    }
}

impl XtremioModel {
    /// Builds the model from hydrated buckets. The returned effects (the
    /// streaming-server settings fetch and the catalog/filter bootstraps)
    /// must be handed to `Runtime::new`.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        profile: Profile,
        library: LibraryBucket,
        streams: StreamsBucket,
        streaming_server_urls: ServerUrlsBucket,
        notifications: NotificationsBucket,
        search_history: SearchHistoryBucket,
        dismissed_events: DismissedEventsBucket,
    ) -> (XtremioModel, Effects) {
        let (discover, discover_effects) = CatalogWithFilters::<MetaItemPreview>::new(&profile);
        let (streaming_server, server_effects) = StreamingServer::new::<XtremioEnv>(&profile);
        let (installed_addons, installed_addons_effects) =
            InstalledAddonsWithFilters::new(&profile);
        let (remote_addons, remote_addons_effects) =
            CatalogWithFilters::<Descriptor>::new(&profile);
        // Before `Ctx::new` takes the buckets, as `WebModel::new` does.
        let (continue_watching_preview, continue_watching_effects) =
            ContinueWatchingPreview::new(&library, &notifications);
        let (library_with_filters, library_effects) =
            LibraryWithFilters::<NotRemovedFilter>::new(&library, &notifications);
        let model = XtremioModel {
            ctx: Ctx::new(
                profile,
                library,
                streams,
                streaming_server_urls,
                notifications,
                search_history,
                dismissed_events,
            ),
            continue_watching_preview,
            board: Default::default(),
            search: Default::default(),
            discover,
            meta_details: Default::default(),
            streaming_server,
            player: Default::default(),
            library: library_with_filters,
            installed_addons,
            remote_addons,
            addon_details: Default::default(),
        };
        (
            model,
            discover_effects
                .join(server_effects)
                .join(continue_watching_effects)
                .join(library_effects)
                .join(installed_addons_effects)
                .join(remote_addons_effects),
        )
    }

    /// Serializes one field to JSON: [`Self::snapshot`] and then
    /// [`FieldSnapshot::into_json`], for a caller that holds nothing else.
    pub fn get_state_json(&self, field: &XtremioModelField) -> serde_json::Result<String> {
        self.snapshot(field)?.into_json()
    }

    /// Takes one field off the model in the cheapest form that no longer
    /// borrows it (see [`FieldSnapshot`]).
    pub fn snapshot(&self, field: &XtremioModelField) -> serde_json::Result<FieldSnapshot> {
        let json = match field {
            XtremioModelField::Board => return Ok(FieldSnapshot::Grid(self.grid(&self.board))),
            XtremioModelField::Search => return Ok(FieldSnapshot::Grid(self.grid(&self.search))),
            XtremioModelField::Ctx => serde_json::to_string(&self.ctx)?,
            XtremioModelField::ContinueWatchingPreview => {
                serde_json::to_string(&self.continue_watching_preview)?
            }
            XtremioModelField::Discover => serde_json::to_string(&self.discover)?,
            XtremioModelField::MetaDetails => self.meta_details_json()?,
            XtremioModelField::StreamingServer => serde_json::to_string(&self.streaming_server)?,
            XtremioModelField::Player => serde_json::to_string(&self.player)?,
            XtremioModelField::Library => serde_json::to_string(&self.library)?,
            XtremioModelField::InstalledAddons => serde_json::to_string(&self.installed_addons)?,
            XtremioModelField::RemoteAddons => serde_json::to_string(&self.remote_addons)?,
            XtremioModelField::AddonDetails => serde_json::to_string(&self.addon_details)?,
        };
        Ok(FieldSnapshot::Json(json))
    }

    /// The board or the search as [`GridJson`]: every page with its items
    /// reduced to [`GridItem`], and a `catalogLabels` array aligned by index
    /// with `catalogs`. The raw model only carries requests; the catalog and
    /// addon names live in the profile's manifests, so they are resolved
    /// here the way stremio-core-web's `serialize_catalogs_with_extra` does
    /// (the same lookup `CatalogsWithExtra` itself uses for `LoadNextPage`).
    /// A catalog whose addon is gone from the profile falls back to its id
    /// and host.
    fn grid(&self, model: &CatalogsWithExtra) -> GridJson {
        let catalogs = model
            .catalogs
            .iter()
            .map(|catalog| {
                catalog
                    .iter()
                    .map(|page| ResourceLoadable {
                        request: page.request.clone(),
                        content: page.content.as_ref().map(|content| match content {
                            Loadable::Loading => Loadable::Loading,
                            Loadable::Ready(items) => {
                                Loadable::Ready(items.iter().map(GridItem::of).collect())
                            }
                            Loadable::Err(error) => Loadable::Err(error.clone()),
                        }),
                    })
                    .collect()
            })
            .collect();
        let catalog_labels = model
            .catalogs
            .iter()
            .map(|catalog| {
                let request = &catalog.first()?.request;
                let addon = self
                    .ctx
                    .profile
                    .addons
                    .iter()
                    .find(|addon| addon.transport_url == request.base);
                let manifest_catalog = addon.and_then(|addon| {
                    addon.manifest.catalogs.iter().find(|catalog| {
                        catalog.id == request.path.id && catalog.r#type == request.path.r#type
                    })
                });
                let addon_name = addon
                    .map(|addon| addon.manifest.name.clone())
                    .or_else(|| request.base.host_str().map(str::to_owned))
                    .unwrap_or_else(|| request.base.to_string());
                let name = manifest_catalog
                    .and_then(|catalog| catalog.name.clone())
                    .unwrap_or_else(|| match addon {
                        Some(_) => addon_name.clone(),
                        None => request.path.id.clone(),
                    });
                Some(CatalogLabel {
                    name,
                    addon_name,
                    r#type: request.path.r#type.clone(),
                })
            })
            .collect();
        GridJson {
            selected: model.selected.clone(),
            catalogs,
            catalog_labels,
        }
    }

    /// `MetaDetails` plus a `watchedVideoIds` array. The engine's `watched`
    /// bitfield is `skip_serializing`, so the watched episode ids are
    /// resolved here (via `WatchedBitField::get_video`) for the UI.
    fn meta_details_json(&self) -> serde_json::Result<String> {
        let mut value = serde_json::to_value(&self.meta_details)?;
        if let (Some(object), Some(watched)) =
            (value.as_object_mut(), self.meta_details.watched.as_ref())
        {
            let watched_ids: Vec<&str> = self
                .meta_details
                .meta_items
                .iter()
                .find_map(|loadable| match &loadable.content {
                    Some(Loadable::Ready(meta)) => Some(meta),
                    _ => None,
                })
                .map(|meta| {
                    meta.videos
                        .iter()
                        .map(|video| video.id.as_str())
                        .filter(|id| watched.get_video(id))
                        .collect()
                })
                .unwrap_or_default();
            object.insert("watchedVideoIds".to_owned(), serde_json::json!(watched_ids));
        }
        serde_json::to_string(&value)
    }
}

/// Parses a `snake_case` field name (`"board"`, `"meta_details"`, ...).
pub fn parse_field(name: &str) -> anyhow::Result<XtremioModelField> {
    serde_json::from_value(serde_json::Value::String(name.to_owned()))
        .map_err(|_| anyhow::anyhow!("unknown model field `{name}`"))
}

/// The `snake_case` name of a field, as used in `NewState` events.
pub fn field_name(field: &XtremioModelField) -> String {
    match serde_json::to_value(field) {
        Ok(serde_json::Value::String(name)) => name,
        _ => format!("{field:?}"),
    }
}

// Keep the serde bound explicit for `field_name`.
fn _assert_field_serializes(field: &XtremioModelField) -> impl Serialize + '_ {
    field
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::*;
    use stremio_core::models::common::ResourceError;
    use stremio_core::runtime::msg::{Action, ActionLoad};
    use stremio_core::runtime::Model as _;
    use stremio_core::types::addon::{ResourcePath, ResourceRequest, ResourceResponse};

    const FIELD_NAMES: [&str; 12] = [
        "ctx",
        "continue_watching_preview",
        "board",
        "search",
        "discover",
        "meta_details",
        "streaming_server",
        "player",
        "library",
        "installed_addons",
        "remote_addons",
        "addon_details",
    ];

    fn default_model() -> XtremioModel {
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

    fn catalog_request(base: &str, r#type: &str, id: &str) -> ResourceRequest {
        ResourceRequest::new(
            url::Url::parse(base).unwrap(),
            ResourcePath::without_extra("catalog", r#type, id),
        )
    }

    fn planned_catalog(
        base: &str,
        r#type: &str,
        id: &str,
    ) -> Vec<ResourceLoadable<Vec<MetaItemPreview>>> {
        vec![ResourceLoadable {
            request: catalog_request(base, r#type, id),
            content: None,
        }]
    }

    /// The items of every `Ready` page of the recorded board fixture: what
    /// Cinemeta really answers, `links` and descriptions included.
    fn recorded_items() -> Vec<MetaItemPreview> {
        let fixture: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/board_default_addons.json"
            ))
            .expect("the board fixture"),
        )
        .expect("valid JSON");
        fixture["catalogs"]
            .as_array()
            .expect("catalogs")
            .iter()
            .flat_map(|pages| pages.as_array().expect("pages"))
            .filter(|page| page["content"]["type"] == "Ready")
            .flat_map(|page| {
                serde_json::from_value::<Vec<MetaItemPreview>>(page["content"]["content"].clone())
                    .expect("recorded items parse back")
            })
            .collect()
    }

    /// A loaded board of `catalogs` Cinemeta-shaped rows with `per_row`
    /// recorded items each -- eight rows of a hundred is what a full
    /// default board is once every row has been scrolled into range.
    fn loaded_board(catalogs: usize, per_row: usize) -> CatalogsWithExtra {
        let items = recorded_items();
        assert!(items.len() >= 50, "the fixture holds three Ready pages");
        let page: Vec<MetaItemPreview> = items.iter().cycle().take(per_row).cloned().collect();
        CatalogsWithExtra {
            selected: Some(Selected {
                r#type: None,
                extra: vec![],
            }),
            catalogs: (0..catalogs)
                .map(|index| {
                    vec![ResourceLoadable {
                        request: catalog_request(
                            "https://v3-cinemeta.strem.io/manifest.json",
                            "movie",
                            &format!("row{index}"),
                        ),
                        content: Some(Loadable::Ready(page.clone())),
                    }]
                })
                .collect(),
        }
    }

    /// What the wire carried before the projection: the whole
    /// `CatalogsWithExtra` through a `Value` tree with the labels inserted,
    /// then written out. Kept here as the yardstick.
    fn whole_document(model: &XtremioModel, catalogs: &CatalogsWithExtra) -> String {
        let mut value = serde_json::to_value(catalogs).unwrap();
        let labels = serde_json::to_value(model.grid(catalogs).catalog_labels).unwrap();
        value
            .as_object_mut()
            .unwrap()
            .insert("catalogLabels".to_owned(), labels);
        serde_json::to_string(&value).unwrap()
    }

    fn best_of<T>(runs: u32, mut f: impl FnMut() -> T) -> (Duration, T) {
        let mut best = Duration::MAX;
        let mut last = None;
        for _ in 0..runs {
            let started = Instant::now();
            let out = f();
            best = best.min(started.elapsed());
            last = Some(out);
        }
        (best, last.unwrap())
    }

    #[test]
    fn field_names_roundtrip() {
        for name in FIELD_NAMES {
            let field = parse_field(name).expect(name);
            assert_eq!(field_name(&field), name);
        }
        assert!(parse_field("metaDetails").is_err());
        assert!(parse_field("nope").is_err());
    }

    #[test]
    fn default_model_serializes_every_field() {
        let model = default_model();
        for name in FIELD_NAMES {
            let json = model
                .get_state_json(&parse_field(name).unwrap())
                .expect(name);
            let value: serde_json::Value = serde_json::from_str(&json).expect(name);
            assert!(value.is_object(), "{name}: {json}");
        }
        let ctx: serde_json::Value =
            serde_json::from_str(&model.get_state_json(&XtremioModelField::Ctx).unwrap()).unwrap();
        assert_eq!(
            ctx["profile"]["settings"]["streamingServerUrl"],
            "http://127.0.0.1:11470/"
        );
    }

    #[test]
    fn continue_watching_preview_starts_empty() {
        let model = default_model();
        let json: serde_json::Value = serde_json::from_str(
            &model
                .get_state_json(&XtremioModelField::ContinueWatchingPreview)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(json, serde_json::json!({ "items": [] }));
    }

    #[test]
    fn library_starts_unloaded_with_the_all_type_and_every_sort() {
        let model = default_model();
        let json: serde_json::Value =
            serde_json::from_str(&model.get_state_json(&XtremioModelField::Library).unwrap())
                .unwrap();
        assert_eq!(json["selected"], serde_json::Value::Null);
        assert_eq!(json["catalog"], serde_json::json!([]));
        // No `rename_all` on this model: snake_case `next_page`.
        assert!(json["selectable"].get("next_page").is_some(), "{json}");
        assert_eq!(json["selectable"]["next_page"], serde_json::Value::Null);
        assert_eq!(
            json["selectable"]["types"],
            serde_json::json!([{
                "type": null,
                "selected": false,
                "request": { "type": null, "sort": "lastwatched", "page": 1 },
            }])
        );
        let sorts: Vec<&str> = json["selectable"]["sorts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|sort| sort["sort"].as_str().unwrap())
            .collect();
        assert_eq!(
            sorts,
            [
                "lastwatched",
                "name",
                "namereverse",
                "timeswatched",
                "watched",
                "notwatched",
            ]
        );
    }

    #[test]
    fn installed_addons_start_unloaded_with_types_from_the_official_addons() {
        let model = default_model();
        let json: serde_json::Value = serde_json::from_str(
            &model
                .get_state_json(&XtremioModelField::InstalledAddons)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(json["selected"], serde_json::Value::Null);
        assert_eq!(json["catalog"], serde_json::json!([]));
        let types = json["selectable"]["types"].as_array().unwrap();
        assert_eq!(
            types[0],
            serde_json::json!({
                "type": null,
                "selected": false,
                "request": { "type": null },
            })
        );
        assert!(
            types
                .iter()
                .any(|entry| entry["type"] == "movie" && entry["request"]["type"] == "movie"),
            "{json}"
        );
    }

    #[test]
    fn remote_addons_start_unloaded_and_share_discovers_shape() {
        let model = default_model();
        let json: serde_json::Value = serde_json::from_str(
            &model
                .get_state_json(&XtremioModelField::RemoteAddons)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(json["selected"], serde_json::Value::Null);
        assert_eq!(json["catalog"], serde_json::json!([]));
        // camelCase here, unlike the library model.
        assert!(json["selectable"].get("nextPage").is_some(), "{json}");
        // Cinemeta's manifest carries the `official` and `community` addon
        // catalogs; the Load with `args: null` picks the first of these.
        let catalogs = json["selectable"]["catalogs"].as_array().unwrap();
        assert!(!catalogs.is_empty(), "{json}");
        for catalog in catalogs {
            assert_eq!(catalog["request"]["path"]["resource"], "addon_catalog");
            assert_eq!(catalog["selected"], false);
        }
        assert!(
            catalogs.iter().any(|catalog| {
                catalog["request"]["base"] == "https://v3-cinemeta.strem.io/manifest.json"
                    && catalog["request"]["path"]["id"] == "community"
            }),
            "{json}"
        );
    }

    #[test]
    fn addon_details_start_empty() {
        let model = default_model();
        let json: serde_json::Value = serde_json::from_str(
            &model
                .get_state_json(&XtremioModelField::AddonDetails)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            json,
            serde_json::json!({ "selected": null, "localAddon": null, "remoteAddon": null })
        );
    }

    #[test]
    fn catalogs_with_extra_carry_empty_labels_when_unloaded() {
        let model = default_model();
        for field in [XtremioModelField::Board, XtremioModelField::Search] {
            let json: serde_json::Value =
                serde_json::from_str(&model.get_state_json(&field).unwrap()).unwrap();
            assert_eq!(json["selected"], serde_json::Value::Null);
            assert_eq!(json["catalogs"], serde_json::json!([]));
            assert_eq!(json["catalogLabels"], serde_json::json!([]));
        }
    }

    #[test]
    fn catalog_labels_resolve_names_from_the_profile_addons() {
        let mut model = default_model();
        model.board = CatalogsWithExtra {
            selected: Some(Selected {
                r#type: None,
                extra: vec![],
            }),
            catalogs: vec![
                planned_catalog("https://v3-cinemeta.strem.io/manifest.json", "movie", "top"),
                // No catalog name in the manifest: the addon name stands in.
                planned_catalog(
                    "https://v3-channels.strem.io/manifest.json",
                    "channel",
                    "top",
                ),
                // Addon not installed (any more): id and host.
                planned_catalog("https://example.org/addon/manifest.json", "movie", "weird"),
            ],
        }
        .into();
        let json: serde_json::Value =
            serde_json::from_str(&model.get_state_json(&XtremioModelField::Board).unwrap())
                .unwrap();
        assert_eq!(json["catalogs"].as_array().unwrap().len(), 3);
        assert_eq!(json["catalogs"][0][0]["content"], serde_json::Value::Null);
        assert_eq!(
            json["catalogLabels"],
            serde_json::json!([
                { "name": "Popular", "addonName": "Cinemeta", "type": "movie" },
                { "name": "YouTube", "addonName": "YouTube", "type": "channel" },
                { "name": "weird", "addonName": "example.org", "type": "movie" },
            ])
        );
    }

    /// The board's and the search's items go over as what a poster tile
    /// draws, and every page keeps the shape stremio-core gives it -- the
    /// Dart side reads `content.type` and the request off each page exactly
    /// as it did when the whole item crossed.
    #[test]
    fn board_items_are_the_grid_projection_and_pages_keep_their_shape() {
        let items = recorded_items();
        let item = &items[0];
        assert!(
            !item.links.is_empty(),
            "the yardstick item has links to lose"
        );
        assert!(item.description.is_some());
        let base = "https://v3-cinemeta.strem.io/manifest.json";
        let mut model = default_model();
        for field in [XtremioModelField::Board, XtremioModelField::Search] {
            let catalogs = CatalogsWithExtra {
                selected: Some(Selected {
                    r#type: Some("movie".to_owned()),
                    extra: vec![],
                }),
                catalogs: vec![
                    vec![ResourceLoadable {
                        request: catalog_request(base, "movie", "top"),
                        content: Some(Loadable::Ready(vec![item.clone()])),
                    }],
                    vec![ResourceLoadable {
                        request: catalog_request(base, "movie", "loading"),
                        content: Some(Loadable::Loading),
                    }],
                    vec![ResourceLoadable {
                        request: catalog_request(base, "movie", "empty"),
                        content: Some(Loadable::Err(ResourceError::EmptyContent)),
                    }],
                ],
            };
            match field {
                XtremioModelField::Board => model.board = catalogs.into(),
                _ => model.search = catalogs.into(),
            }
            let json: serde_json::Value =
                serde_json::from_str(&model.get_state_json(&field).unwrap()).unwrap();
            assert_eq!(
                json["selected"],
                serde_json::json!({ "type": "movie", "extra": [] })
            );
            let page = &json["catalogs"][0][0];
            assert_eq!(page["request"]["base"], base);
            assert_eq!(page["request"]["path"]["id"], "top");
            assert_eq!(page["content"]["type"], "Ready");
            assert_eq!(
                page["content"]["content"][0],
                serde_json::json!({
                    "id": item.id,
                    "type": item.r#type,
                    "name": item.name,
                    "poster": item.poster,
                    "posterShape": "poster",
                    "releaseInfo": item.release_info,
                }),
                "the six fields a tile reads, and no others"
            );
            assert_eq!(
                json["catalogs"][1][0]["content"],
                serde_json::json!({ "type": "Loading" })
            );
            assert_eq!(
                json["catalogs"][2][0]["content"],
                serde_json::json!({ "type": "Err", "content": { "type": "EmptyContent" } })
            );
            assert_eq!(json["catalogLabels"].as_array().map(Vec::len), Some(3));
            assert_eq!(json["catalogLabels"][0]["name"], "Popular");
        }
    }

    /// A library change -- a pause, the 90 s progress push, a title kept --
    /// is not a change to the board or the search: nothing they put on the
    /// wire reads the library, and the field was re-pulled whole on every
    /// one. A load still is a change, so the filter is not a gag.
    #[test]
    fn a_library_change_does_not_touch_the_board_or_the_search() {
        let mut model = default_model();
        let (_effects, fields) = model.update_field(
            &Msg::Action(Action::Load(ActionLoad::CatalogsWithExtra(Selected {
                r#type: None,
                extra: vec![],
            }))),
            &XtremioModelField::Board,
        );
        assert_eq!(fields, vec![XtremioModelField::Board], "a load is a change");

        let (_effects, fields) = model.update(&Msg::Internal(Internal::LibraryChanged(true)));
        assert!(
            !fields.contains(&XtremioModelField::Board),
            "the board is not re-emitted: {fields:?}"
        );
        assert!(
            !fields.contains(&XtremioModelField::Search),
            "nor is the search: {fields:?}"
        );
        // The wrapped model is untouched by the filtering.
        assert_eq!(
            model.board.catalogs.len(),
            6,
            "the default addons' six catalogs"
        );
    }

    /// The snapshot of a board owns what it needs: it is taken under the
    /// model's read lock and serialized after the lock is gone, which is a
    /// property of the type (this test would not compile against a
    /// borrowing one) as much as of the bytes. The numbers it prints are
    /// what the projection buys against the whole document that crossed
    /// before it, on an eight-by-hundred board -- run with `--nocapture`.
    #[test]
    fn a_board_snapshot_outlives_the_model_and_is_a_fraction_of_the_document() {
        let mut model = default_model();
        model.board = loaded_board(8, 100).into();

        let (whole_took, whole) = best_of(5, || whole_document(&model, &model.board));
        let (snapshot_took, snapshot) = best_of(5, || model.snapshot(&XtremioModelField::Board));
        let snapshot = snapshot.unwrap();
        drop(model);
        let (write_took, grid) = best_of(5, || {
            serde_json::to_string(match &snapshot {
                FieldSnapshot::Grid(grid) => grid,
                FieldSnapshot::Json(_) => panic!("a board is a grid"),
            })
            .unwrap()
        });
        println!(
            "board 8x100: whole document {} bytes in {whole_took:?}; \
             projection {} bytes, snapshot (under the lock) {snapshot_took:?} \
             + write (outside it) {write_took:?}",
            whole.len(),
            grid.len()
        );
        assert!(
            grid.len() * 5 < whole.len(),
            "the grid is under a fifth of the document: {} vs {}",
            grid.len(),
            whole.len()
        );
        let value: serde_json::Value = serde_json::from_str(&grid).unwrap();
        assert_eq!(value["catalogs"].as_array().map(Vec::len), Some(8));
        assert_eq!(
            value["catalogs"][7][0]["content"]["content"]
                .as_array()
                .map(Vec::len),
            Some(100)
        );
    }

    /// One OpenSubtitles v3 entry, as the addon actually answers: the three
    /// properties the protocol specifies plus the five it does not.
    fn an_opensubtitles_answer() -> serde_json::Value {
        serde_json::json!({
            "subtitles": [
                {
                    "id": "1955625223",
                    "url": "https://opensubtitles-v3.strem.io/subtitles/1955625223.srt",
                    "lang": "eng",
                    "SubEncoding": "CP1252",
                    "fpsMilli": 23980,
                    "subtitleFileName": "The.Godfather.1972.1080p.BluRay.x264.srt",
                    "movieReleaseName": "The Godfather (1972) 1080p BluRay",
                    "releaseGroup": "DFN"
                },
                { "id": "bare", "url": "https://example.org/bare.srt", "lang": "pol" }
            ]
        })
    }

    /// The properties an addon sends beyond `id`/`url`/`lang` are what tells
    /// thirty-odd English uploads apart and what says a subtitle was cut for
    /// 25 fps. They only survive because stremio-core is pinned to a rev that
    /// keeps them in `Subtitles::other`; upstream drops them in serde. Nothing
    /// in `get_state_json` has to know about them -- which is exactly why this
    /// guard is here, so a future pin bump that loses them fails a test
    /// instead of quietly emptying the subtitle menu's labels.
    #[test]
    fn addon_specific_subtitle_properties_reach_the_player_json() {
        let ResourceResponse::Subtitles { subtitles } =
            serde_json::from_value(an_opensubtitles_answer()).expect("a subtitles response")
        else {
            panic!("the response names the subtitles resource");
        };
        let mut model = default_model();
        model.player.subtitles = vec![ResourceLoadable {
            request: ResourceRequest::new(
                url::Url::parse("https://opensubtitles-v3.strem.io/manifest.json").unwrap(),
                ResourcePath::without_extra("subtitles", "movie", "tt0068646"),
            ),
            content: Some(Loadable::Ready(subtitles)),
        }];

        let json: serde_json::Value =
            serde_json::from_str(&model.get_state_json(&XtremioModelField::Player).unwrap())
                .unwrap();
        let entries = &json["subtitles"][0]["content"]["content"];
        assert_eq!(entries.as_array().map(Vec::len), Some(2), "{json}");

        // Verbatim: the names are the addon's, the numbers are still numbers,
        // and the casing of `SubEncoding` is not normalized on the way out.
        assert_eq!(
            entries[0],
            serde_json::json!({
                "id": "1955625223",
                "url": "https://opensubtitles-v3.strem.io/subtitles/1955625223.srt",
                "lang": "eng",
                "SubEncoding": "CP1252",
                "fpsMilli": 23980,
                "subtitleFileName": "The.Godfather.1972.1080p.BluRay.x264.srt",
                "movieReleaseName": "The Godfather (1972) 1080p BluRay",
                "releaseGroup": "DFN",
            })
        );
        // An entry that sent nothing extra gains nothing: the catch-all is
        // flattened, so an empty one adds no key of its own.
        assert_eq!(
            entries[1],
            serde_json::json!({
                "id": "bare",
                "url": "https://example.org/bare.srt",
                "lang": "pol",
            })
        );
    }
}
