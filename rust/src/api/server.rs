//! FRB surface for the embedded stream-server: lifecycle, and the control
//! calls the app makes itself (torrent start-up stats, server settings) as
//! JSON strings over the server's library API -- the Dart side never
//! speaks HTTP to the server; only the player fetches media from it.

use flutter_rust_bridge::frb;

use crate::guard::{guarded, guarded_ok};

/// Where and how the embedded server runs. Directories are decided by Dart
/// (path_provider) and created by Rust if missing.
pub struct ServerConfig {
    /// App-support directory for settings.json, logs/, localFiles/.
    pub config_dir: String,
    /// App-cache directory for the torrent piece cache.
    pub cache_dir: String,
    /// Port on 127.0.0.1; 11470 is stremio-core's default, 0 = ephemeral.
    pub port: u16,
    /// Retry with an ephemeral port if `port` is taken.
    pub fallback_to_ephemeral: bool,
}

impl From<ServerConfig> for crate::server::StartConfig {
    fn from(config: ServerConfig) -> Self {
        Self {
            config_dir: config.config_dir.into(),
            cache_dir: config.cache_dir.into(),
            port: config.port,
            fallback_to_ephemeral: config.fallback_to_ephemeral,
        }
    }
}

/// Starts the embedded server (idempotent) and returns its base URL, e.g.
/// `http://127.0.0.1:11470/`.
pub fn server_start(config: ServerConfig) -> anyhow::Result<String> {
    guarded(|| crate::server::start(config.into()).map(|url| url.to_string()))
}

/// Stops the embedded server and joins its thread. Ok if it is not running.
pub fn server_stop() -> anyhow::Result<()> {
    guarded(crate::server::stop)
}

/// Base URL of the running embedded server, or null when it is stopped.
#[frb(sync)]
pub fn server_base_url() -> anyhow::Result<Option<String>> {
    guarded_ok(|| crate::server::base_url().map(|url| url.to_string()))
}

/// A torrent's `stats.json` as JSON (camelCase, the shape stremio-core's
/// `Statistics` parses plus the start-up `phase` fields and an optional
/// `error` message): the per-file stats when `file_idx` is set, the
/// torrent-level ones otherwise. `trackers` is the stream's `announce`
/// list, used only if this call is what creates the torrent's engine.
/// Errors when the server is not running, for a negative index, or for an
/// index the torrent does not have once its metadata is known. Blocks the
/// FRB worker while the server answers; never call from the UI thread.
pub fn server_torrent_stats(
    info_hash: String,
    file_idx: Option<i64>,
    trackers: Vec<String>,
) -> anyhow::Result<String> {
    guarded(|| {
        let file_idx = file_idx
            .map(|idx| {
                usize::try_from(idx).map_err(|_| anyhow::anyhow!("invalid file index {idx}"))
            })
            .transpose()?;
        let stats = crate::server::torrent_stats(&info_hash, file_idx, &trackers)?;
        serde_json::to_string(&stats).map_err(Into::into)
    })
}

/// The embedded server's settings as JSON (the `values` of `GET /settings`:
/// `cacheSize`, `btMaxConnections`, ...). Errors when it is not running.
pub fn server_settings() -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::server::settings()?).map_err(Into::into))
}

/// Applies `patch_json` (a JSON object of settings keys) exactly as
/// `POST /settings` would -- same keys, validation, engine update and
/// persistence -- and returns the settings afterwards as JSON. Errors on
/// malformed JSON, a rejected value, or when the server is not running.
pub fn server_update_settings(patch_json: String) -> anyhow::Result<String> {
    guarded(|| {
        let patch: serde_json::Value = serde_json::from_str(&patch_json)
            .map_err(|error| anyhow::anyhow!("invalid settings patch JSON: {error}"))?;
        let settings = crate::server::update_settings(patch)?;
        serde_json::to_string(&settings).map_err(Into::into)
    })
}

/// What the server's storage costs right now, as JSON: the cache
/// directory, the bytes under it, the `cacheSize` limit, and the free and
/// total space of the volume it is on (plus the downloads volume when that
/// is a different filesystem).
///
/// The first question about a playback that misbehaves is whether the
/// device is full -- bytes arriving with no verified progress is what
/// failing writes look like -- and the second is whether the cache is over
/// its limit. stream-server answers neither today: its cleaner is private
/// and there is no route or library call for either number, so this walks
/// the cache root itself and asks the filesystem for the rest.
///
/// Blocks the FRB worker (a settings call and a directory walk); never
/// call it from the UI thread. Errors when the server is not running.
pub fn server_storage_report() -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::storage::report()?).map_err(Into::into))
}

/// What the server's cache currently occupies against its `cacheSize`
/// limit, as JSON (`CacheUsage`: `totalBytes`, `limitBytes` -- null only
/// when the cache is truly unlimited -- `protectedBytes`, `protectedFiles`).
/// `protectedBytes`/`protectedFiles` are what a live engine or a pinned
/// download is holding right now, which a clean pass can never take: when
/// they equal `totalBytes` and the cache is still over `limitBytes`,
/// cleaning cannot help until playback stops or something is unpinned.
///
/// Costs one `stat` per file currently in the cache -- the same walk the
/// server's own cleaner already runs on every debounced or hourly pass --
/// so one call per screen open or manual refresh is cheap, but it is not
/// bounded or cached on the server side: do not poll it on a timer. Blocks
/// the FRB worker; never call from the UI thread. Errors when the server is
/// not running.
pub fn server_cache_usage() -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::server::cache_usage()?).map_err(Into::into))
}

/// Runs one eviction pass on the server's cache right now and answers what
/// it did, as JSON (`EvictionReport`: `total`, `protected`,
/// `protectedFiles`, `freed`, `deleted`, `limit`).
///
/// This is the exact function the server's own scheduled sweep calls, so it
/// respects exactly the same protections: nothing a live engine is writing
/// or a pin keeps is ever touched, however far over the limit the cache is.
/// **Nothing here stops playback** -- unlike the restart this replaces,
/// which was the only way to ask stream-server's cleaner for a sweep before
/// it exposed this call. When `total` is still over `limit` afterwards,
/// that is not a failure: `protected`/`protectedFiles` name what is
/// currently unreachable, and the fix is to stop the stream or unpin the
/// download, not to run this again.
///
/// Blocks the FRB worker; never call from the UI thread. Errors when the
/// server is not running.
pub fn server_clean_cache_now() -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::server::clean_cache_now()?).map_err(Into::into))
}

/// The mainline DHT's status on this host, as JSON (`DhtStatus`: `enabled`,
/// `nodes`, `nodesV6`, `everBootstrapped`) -- exactly the `dht` key of
/// `GET /stats.json` (`ServerHandle::dht_status`).
///
/// This is information, not a failure. The DHT is a peer *source*, not a
/// requirement: a torrent with working trackers downloads fine without one,
/// and a network that drops the DHT's UDP (carrier-grade NAT, a firewalled
/// mobile APN, a captive portal) leaves `everBootstrapped` false for the
/// whole session with nothing actually wrong. The one case worth telling a
/// curious person about is a stream with no trackers on a network where the
/// DHT never came up -- that genuinely may not find peers. `enabled: false`
/// answers the same whether the server is not running or its backend has
/// no DHT at all; this call never errors on its account.
///
/// Cheap (two routing-table length reads) and synchronous -- safe to call
/// from the UI thread. Still, nothing should poll it on a timer of its own:
/// read it on screen-open, or piggyback it on a poll that is already
/// running for another reason (the player's stats panel).
#[frb(sync)]
pub fn server_dht_status() -> anyhow::Result<String> {
    guarded_ok(|| serde_json::to_string(&crate::server::dht_status()).unwrap_or_default())
}

/// Starts or stops the server's LAN media listener and answers the address
/// it is bound to afterwards (`"0.0.0.0:39271"`), or null after a stop.
///
/// The listener is a second HTTP listener serving media bytes to the local
/// network -- what a Chromecast fetches from, since it cannot reach the
/// loopback one. It mounts no control route at all, and deliberately not
/// `/proxy` or `/ftp`, so a stream that is only playable through the proxy
/// cannot be cast; the caller has to notice that itself rather than hand a
/// receiver a URL that will 404.
///
/// It exists for the length of a cast session and no longer. Turning it on
/// also grants the server's `lanMediaEnabled` permission and turning it off
/// takes it back, so the persisted answer to "may this app serve the LAN" is
/// no whenever nothing is casting. Errors when the server is not running or
/// the bind fails; in either case nothing is listening afterwards.
pub fn server_set_lan_media(enabled: bool) -> anyhow::Result<Option<String>> {
    guarded(|| Ok(crate::server::set_lan_media(enabled)?.map(|addr| addr.to_string())))
}

/// Whether the LAN media listener is running. False when the server is not
/// running either -- both mean nothing of ours is on the LAN.
#[frb(sync)]
pub fn server_lan_media_running() -> anyhow::Result<bool> {
    guarded_ok(crate::server::lan_media_running)
}

/// The base URL to give a receiver at `peer_ip` (`"http://192.168.1.20:39271/"`),
/// so a media URL built on it names an interface that receiver can connect
/// back to -- the one sharing the receiver's subnet, since the first
/// interface on a host with a VPN or a container bridge regularly is not.
///
/// `peer_ip` is null when the receiver's address is not known. The Cast SDK
/// does not report one, so in practice it usually is: the answer is then the
/// first non-loopback interface, which is what the server falls back to for
/// a peer it cannot place on any subnet, and is right on a device with one
/// network. It is a parameter, and not simply left out, because a receiver
/// whose address *is* known deserves the better answer.
///
/// Null when the listener is not running, when `peer_ip` is given but is not
/// an IP address, or when the host has nothing but loopback -- all of which
/// mean this receiver cannot be handed a URL, and none of which may be
/// answered with a loopback URL it could never fetch.
pub fn server_lan_media_base_url(peer_ip: Option<String>) -> anyhow::Result<Option<String>> {
    guarded(|| {
        // `0.0.0.0` is on no interface's subnet, so it is how "no particular
        // peer" asks the server for its best-effort interface.
        let peer = match peer_ip {
            None => std::net::IpAddr::V4(std::net::Ipv4Addr::UNSPECIFIED),
            Some(text) => match text.parse() {
                Ok(peer) => peer,
                Err(_) => return Ok(None),
            },
        };
        Ok(crate::server::lan_media_base_url(peer).map(|url| url.to_string()))
    })
}
