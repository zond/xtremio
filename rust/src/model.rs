//! `XtremioModel`: the app model the stremio-core Runtime drives.
//!
//! A trimmed `WebModel`: the mandatory `ctx` plus one field per screen the
//! app renders today. `#[derive(Model)]` generates `XtremioModelField` (a
//! `snake_case` serde enum, one variant per field) and the `update` /
//! `update_field` dispatch. Every field is serialized to JSON with serde for
//! the Dart side; there is no per-type mirroring.

use serde::Serialize;
use stremio_core::models::catalog_with_filters::CatalogWithFilters;
use stremio_core::models::catalogs_with_extra::CatalogsWithExtra;
use stremio_core::models::common::Loadable;
use stremio_core::models::ctx::Ctx;
use stremio_core::models::meta_details::MetaDetails;
use stremio_core::models::player::Player;
use stremio_core::models::streaming_server::StreamingServer;
use stremio_core::runtime::Effects;
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
    /// Home: every catalog of every installed addon
    /// (`ActionLoad::CatalogsWithExtra`).
    pub board: CatalogsWithExtra,
    /// One catalog with its filters (`ActionLoad::CatalogWithFilters`).
    pub discover: CatalogWithFilters<MetaItemPreview>,
    /// Meta + per-addon streams for one item (`ActionLoad::MetaDetails`).
    pub meta_details: MetaDetails,
    /// The embedded stream-server as the engine sees it (settings, base
    /// URL, torrent creation).
    pub streaming_server: StreamingServer,
    /// Playback state for the selected stream (`ActionLoad::Player`).
    pub player: Player,
}

impl XtremioModel {
    /// Builds the model from hydrated buckets. The returned effects (the
    /// streaming-server settings fetch and the discover catalog bootstrap)
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
            board: Default::default(),
            discover,
            meta_details: Default::default(),
            streaming_server,
            player: Default::default(),
        };
        (model, discover_effects.join(server_effects))
    }

    /// Serializes one field to JSON.
    pub fn get_state_json(&self, field: &XtremioModelField) -> serde_json::Result<String> {
        match field {
            XtremioModelField::Ctx => serde_json::to_string(&self.ctx),
            XtremioModelField::Board => serde_json::to_string(&self.board),
            XtremioModelField::Discover => serde_json::to_string(&self.discover),
            XtremioModelField::MetaDetails => self.meta_details_json(),
            XtremioModelField::StreamingServer => serde_json::to_string(&self.streaming_server),
            XtremioModelField::Player => serde_json::to_string(&self.player),
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
    use super::*;

    #[test]
    fn field_names_roundtrip() {
        for name in [
            "ctx",
            "board",
            "discover",
            "meta_details",
            "streaming_server",
            "player",
        ] {
            let field = parse_field(name).expect(name);
            assert_eq!(field_name(&field), name);
        }
        assert!(parse_field("metaDetails").is_err());
        assert!(parse_field("nope").is_err());
    }

    #[test]
    fn default_model_serializes_every_field() {
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
        for name in [
            "ctx",
            "board",
            "discover",
            "meta_details",
            "streaming_server",
            "player",
        ] {
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
}
