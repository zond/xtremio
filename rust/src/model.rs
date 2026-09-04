//! `XtremioModel`: the app model the stremio-core Runtime drives.
//!
//! A trimmed `WebModel`: the mandatory `ctx` plus one field per screen the
//! app renders (or is about to render). `#[derive(Model)]` generates `XtremioModelField` (a
//! `snake_case` serde enum, one variant per field) and the `update` /
//! `update_field` dispatch. Every field is serialized to JSON with serde for
//! the Dart side; there is no per-type mirroring.

use serde::Serialize;
use stremio_core::models::addon_details::AddonDetails;
use stremio_core::models::catalog_with_filters::CatalogWithFilters;
use stremio_core::models::catalogs_with_extra::CatalogsWithExtra;
use stremio_core::models::common::Loadable;
use stremio_core::models::continue_watching_preview::ContinueWatchingPreview;
use stremio_core::models::ctx::Ctx;
use stremio_core::models::installed_addons_with_filters::InstalledAddonsWithFilters;
use stremio_core::models::library_with_filters::{LibraryWithFilters, NotRemovedFilter};
use stremio_core::models::meta_details::MetaDetails;
use stremio_core::models::player::Player;
use stremio_core::models::streaming_server::StreamingServer;
use stremio_core::runtime::Effects;
use stremio_core::types::addon::Descriptor;
use stremio_core::types::events::DismissedEventsBucket;
use stremio_core::types::library::LibraryBucket;
use stremio_core::types::notifications::NotificationsBucket;
use stremio_core::types::profile::Profile;
use stremio_core::types::resource::MetaItemPreview;
use stremio_core::types::search_history::SearchHistoryBucket;
use stremio_core::types::server_urls::ServerUrlsBucket;
use stremio_core::types::streams::StreamsBucket;
use stremio_core::Model;

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
    pub board: CatalogsWithExtra,
    /// Search results: every catalog supporting the `search` extra
    /// (`ActionLoad::CatalogsWithExtra` with `["search", query]`).
    pub search: CatalogsWithExtra,
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

    /// Serializes one field to JSON.
    pub fn get_state_json(&self, field: &XtremioModelField) -> serde_json::Result<String> {
        match field {
            XtremioModelField::Ctx => serde_json::to_string(&self.ctx),
            XtremioModelField::ContinueWatchingPreview => {
                serde_json::to_string(&self.continue_watching_preview)
            }
            XtremioModelField::Board => self.catalogs_with_extra_json(&self.board),
            XtremioModelField::Search => self.catalogs_with_extra_json(&self.search),
            XtremioModelField::Discover => serde_json::to_string(&self.discover),
            XtremioModelField::MetaDetails => self.meta_details_json(),
            XtremioModelField::StreamingServer => serde_json::to_string(&self.streaming_server),
            XtremioModelField::Player => serde_json::to_string(&self.player),
            XtremioModelField::Library => serde_json::to_string(&self.library),
            XtremioModelField::InstalledAddons => serde_json::to_string(&self.installed_addons),
            XtremioModelField::RemoteAddons => serde_json::to_string(&self.remote_addons),
            XtremioModelField::AddonDetails => serde_json::to_string(&self.addon_details),
        }
    }

    /// `CatalogsWithExtra` plus a `catalogLabels` array aligned by index with
    /// `catalogs`. The raw model only carries requests; the catalog and addon
    /// names live in the profile's manifests, so they are resolved here the
    /// way stremio-core-web's `serialize_catalogs_with_extra` does (the same
    /// lookup `CatalogsWithExtra` itself uses for `LoadNextPage`). A catalog
    /// whose addon is gone from the profile falls back to its id and host.
    fn catalogs_with_extra_json(&self, model: &CatalogsWithExtra) -> serde_json::Result<String> {
        let mut value = serde_json::to_value(model)?;
        let labels: Vec<serde_json::Value> = model
            .catalogs
            .iter()
            .map(|catalog| {
                let Some(request) = catalog.first().map(|page| &page.request) else {
                    return serde_json::Value::Null;
                };
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
                serde_json::json!({
                    "name": name,
                    "addonName": addon_name,
                    "type": request.path.r#type,
                })
            })
            .collect();
        if let Some(object) = value.as_object_mut() {
            object.insert("catalogLabels".to_owned(), serde_json::json!(labels));
        }
        serde_json::to_string(&value)
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
    use super::*;
    use stremio_core::models::catalogs_with_extra::Selected;
    use stremio_core::models::common::ResourceLoadable;
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

    fn planned_catalog(
        base: &str,
        r#type: &str,
        id: &str,
    ) -> Vec<ResourceLoadable<Vec<MetaItemPreview>>> {
        vec![ResourceLoadable {
            request: ResourceRequest::new(
                url::Url::parse(base).unwrap(),
                ResourcePath::without_extra("catalog", r#type, id),
            ),
            content: None,
        }]
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
        };
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
