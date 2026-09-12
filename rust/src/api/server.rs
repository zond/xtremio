//! FRB surface for the embedded stream-server: lifecycle, and the control
//! calls the app makes itself (torrent start-up stats, server settings) as
//! JSON strings over the server's library API -- the Dart side never
//! speaks HTTP to the server; only the player fetches media from it.

use flutter_rust_bridge::frb;

use crate::guard::{guarded, guarded_ok};

/// Where the embedded server runs. Directories are decided by Dart
/// (path_provider) and created by Rust if missing.
///
/// No port: the server binds an ephemeral loopback one and the app reads the
/// address back off the handle (`server_start` returns it, and `core_init`
/// retargets stremio-core at it). There used to be `port` and
/// `fallback_to_ephemeral` here, defaulting to 11470 because that is what
/// stremio-core's default profile points at -- but nothing downstream reads
/// the number, so all a preferred port could do was collide.
pub struct ServerConfig {
    /// App-support directory for settings.json, logs/, localFiles/.
    pub config_dir: String,
    /// App-cache directory for the torrent piece cache.
    pub cache_dir: String,
}

impl From<ServerConfig> for crate::server::StartConfig {
    fn from(config: ServerConfig) -> Self {
        Self {
            config_dir: config.config_dir.into(),
            cache_dir: config.cache_dir.into(),
        }
    }
}

/// Starts the embedded server (idempotent) and returns its base URL --
/// `http://127.0.0.1:<port the OS picked>/`, which is the only place that
/// port is ever known.
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

/// **Tells the server where the player is.** `film_seconds` is where the
/// player is in the *picture* -- mpv's `time-pos`, the number the progress
/// bar draws -- and `duration_seconds` how long the picture is (zero or
/// negative for "the player does not know").
///
/// The server infers the playhead from byte ranges otherwise, and a byte
/// range does not carry it: mpv reads the container index with the same
/// kind of request it seeks with, and keeps a second reader crawling that
/// index while it plays. Told directly, the retention window sits on the
/// film.
///
/// Deliberately not the player's own byte offset. `stream-pos` is where
/// the demuxer has *read* to, and it reads that index as readily as the
/// film, so reporting it faithfully puts the window at the end of the file
/// while the viewer is sixteen minutes in -- the same failure being told
/// was meant to fix. There is only one `time-pos`. The server converts it
/// at the film's average rate and lets a nearby read correct the drift.
///
/// The duration is the other half and is not a hint about position at all:
/// with the file's own size it *is* the film's bitrate, which is what sizes
/// a window measured in seconds. The server used to estimate that from how
/// fast bytes left it, and produced three bytes a second and then seventeen
/// on two successive field runs, each of which collapsed the window onto
/// its floor and stopped playback. Size over duration is arithmetic.
///
/// Call it about once a second while a film is open. **It never errors and
/// never blocks on the network**: a server that is not running, a torrent
/// this process is not streaming, a nonsensical number -- all are nothing
/// to say, said silently. Stop calling and the hint goes stale in fifteen
/// seconds and the server's own inference answers again.
pub fn server_note_playhead(
    info_hash: String,
    file_idx: i64,
    film_seconds: f64,
    duration_seconds: f64,
) -> anyhow::Result<()> {
    guarded_ok(move || {
        let Ok(file_idx) = usize::try_from(file_idx) else {
            return;
        };
        // `Duration::from_secs_f64` panics on a negative or a NaN, and both
        // numbers come from a player through Dart. A position of zero is the
        // start of the film and is meant; a length of zero is a film whose
        // length the player does not know yet, and is not.
        if !film_seconds.is_finite() || film_seconds < 0.0 {
            return;
        }
        let film = std::time::Duration::from_secs_f64(film_seconds);
        let duration = (duration_seconds.is_finite() && duration_seconds > 0.0)
            .then(|| std::time::Duration::from_secs_f64(duration_seconds));
        crate::server::note_playhead(&info_hash, file_idx, film, duration);
    })
}

/// **Tells the server how long the film is**, with no position: what a cast
/// can state, the receiver reporting seconds that do not convert to a byte
/// offset. The length is what sizes the retention window.
///
/// Never errors and never blocks on the network, exactly as
/// `server_note_playhead` does not.
pub fn server_note_duration(
    info_hash: String,
    file_idx: i64,
    duration_seconds: f64,
) -> anyhow::Result<()> {
    guarded_ok(move || {
        let Ok(file_idx) = usize::try_from(file_idx) else {
            return;
        };
        if !duration_seconds.is_finite() || duration_seconds <= 0.0 {
            return;
        }
        crate::server::note_duration(
            &info_hash,
            file_idx,
            std::time::Duration::from_secs_f64(duration_seconds),
        );
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
        let patch: serde_json::Value = serde_json::from_str(&patch_json).map_err(|error| {
            anyhow::anyhow!(
                "invalid settings patch JSON: {}",
                crate::serde_fault::cause(&error)
            )
        })?;
        let settings = crate::server::update_settings(patch)?;
        serde_json::to_string(&settings).map_err(Into::into)
    })
}

/// What the server's storage costs right now, as JSON: the one torrent-data
/// root, what the cache under it occupies, the `cacheSize` limit, and the
/// free and total space of the volume it is on. One root and one volume:
/// the streaming cache and everything kept offline are the same pieces in
/// the same store, so there is no second tree and no second volume.
///
/// The first question about a playback that misbehaves is whether the
/// device is full -- bytes arriving with no verified progress is what
/// failing writes look like -- and the second is whether the cache is over
/// its limit. The occupancy is the server's own figure, the `totalBytes`
/// of `server_cache_usage`, so the two calls cannot disagree about it; the
/// volume's room is asked of the filesystem.
///
/// Blocks the FRB worker (two calls into the server and a `statvfs`);
/// never call it from the UI thread. Errors when the server is not running.
pub fn server_storage_report() -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::storage::report()?).map_err(Into::into))
}

/// What the server's cache currently occupies against the limit in force,
/// as JSON (`CacheUsage`: `totalBytes`, `limitBytes`, `protectedBytes`,
/// `protectedFiles`).
///
/// `limitBytes` is the smaller of the `cacheSize` setting and what the
/// volume can give while keeping the server's 512 MiB free-space floor
/// clear, so it is a number even with no `cacheSize` set, it is derived
/// from free space and so moves when anything else on the device writes,
/// and it is null only when neither caps anything. It is a different
/// question from `server_storage_report`'s `cacheLimitBytes`, which is the
/// setting itself.
/// `protectedBytes`/`protectedFiles` are what a pinned download or the
/// window of the stream being played holds right now, which a clean can
/// never take: when they equal `totalBytes` and the cache is still over
/// `limitBytes`, cleaning cannot help until playback moves on or something
/// is unpinned.
///
/// Counted from what the server's two owners say they hold -- the piece
/// store and the proxy cache -- plus one listing of the store root, not a
/// walk of the tree, so a call per screen open or manual refresh is cheap.
/// Nothing caches the answer, so do not poll it on a sub-second timer.
/// Blocks the FRB worker; never call from the UI thread. Errors when the
/// server is not running.
pub fn server_cache_usage() -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::server::cache_usage()?).map_err(Into::into))
}

/// Gives back everything nobody is playing and nobody is reading, now, and
/// answers what is left, as JSON (`EvictionReport`: `total`, `protected`,
/// `protectedFiles`, `freed`, `deleted`, `limit`, `overLimit`).
/// `freed`/`deleted` are what the call took off the volume; `limit` is the
/// cap in force, on the same terms as `server_cache_usage`'s `limitBytes`
/// -- null for no cap, and 0 for a volume with no room to give, which is a
/// cap and not the absence of one.
///
/// Nothing is picked as a victim: the server asks the owners of the piece
/// store and the proxy cache for their slack, the same passes its own
/// reconciler runs, so a pinned download and the window of the stream being
/// played are never touched however far over the limit the cache is.
/// **Nothing here stops playback.** Freeing nothing is the ordinary answer
/// on a device with one film playing and one pinned; when `overLimit` is
/// not zero, `protected`/`protectedFiles` name what holds the cache there,
/// and the fix is to stop the stream or unpin the download, not to run
/// this again.
///
/// Blocks the FRB worker; never call from the UI thread. Errors when the
/// server is not running.
pub fn server_clean_cache_now() -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::server::clean_cache_now()?).map_err(Into::into))
}

/// Whether the server is moving bytes over this device's connection while
/// nothing is playing, as JSON (`BackgroundTraffic`: `active`,
/// `downloading`, `uploading`, `playing`, `bytesDownloaded`,
/// `bytesUploaded`, `windowSecs`) -- `ServerHandle::background_traffic`,
/// what the activity light reads.
///
/// `downloading` and `uploading` are each "that direction's peer counter
/// grew over the last five-second window and nothing was playing over it
/// or since", `active` is either, and `playing` is the moment's own answer
/// so a caller can tell "dark because idle" from "dark because a film is
/// on" without a second call. The conjunction with playback is taken on
/// the Rust side over one sample; do not rebuild it in Dart from two
/// calls, which would flicker whenever they disagree. The counters are the
/// sums the verdict was judged from, over the torrents that exist right
/// now -- a torrent that pauses or leaves takes its bytes with it.
///
/// **Safe to poll every few seconds.** The server peeks at counters
/// librqbit already keeps for the engines that exist: no hash is looked up
/// so no engine is created, and no idle clock is touched so a poll never
/// keeps a torrent seeding to report on it. `server_torrent_stats` is the
/// opposite -- it creates the engine it is asked about -- and must never
/// stand in for this. The verdict changes when a window closes or the
/// moment playback is seen; asking faster is answered from the standing
/// reading.
///
/// Blocks the FRB worker for one hop onto the server's runtime; never call
/// from the UI thread. Errors when the server is not running, which a
/// caller draws as dark.
pub fn server_background_traffic() -> anyhow::Result<String> {
    guarded(|| serde_json::to_string(&crate::server::background_traffic()?).map_err(Into::into))
}

/// What this server holds of the stream `url` is playing, as JSON
/// (`StreamNumbers`: `window` -- `behindBytes`/`aheadBytes` -- and, for a
/// torrent, `sharing` -- `committedBytes` and a `transfer` group of
/// `downloadedBytes`/`uploadedBytes`/`ratio`), or null when this server
/// holds nothing of that stream.
///
/// `url` is the URL handed to the player, and its shape is the whole
/// question: `/{infoHash}/{fileIdx}` (including `-1`, resolved through the
/// same `f=` filters the stream route uses) reads the piece store,
/// `/proxy/...` reads the proxy cache, and anything else -- an addon's
/// direct link, a debrid URL, a file on the device -- is a stream this
/// server is not holding. **Null there is an answer, not a failure**: a
/// caller draws no rows and shows no error.
///
/// Every `null` inside is "there is no such number", never zero, and a
/// caller must draw an absent row rather than a dash: no `window` where no
/// retention policy is bounding the stream (a torrent the budget covers,
/// or nothing read yet), no `sharing` for a proxied response (it is not
/// seeded, so it has no committed set and no ratio), no `committedBytes`
/// for a torrent with no policy, and no `transfer` for a torrent whose
/// counters cannot be read -- paused, checking, stopped for space, in
/// error. A torrent that has moved gigabytes and then paused has not moved
/// nothing.
///
/// **The transfer totals cover the torrent's current live period** --
/// librqbit's per-torrent counters, which live in the live state and start
/// at zero each time the torrent enters it, so a pause and resume or an
/// idle drop and re-add starts them over -- and the ratio taken from them
/// must be labelled as that period and not as the session. Nothing is
/// persisted, so nothing read back here is a claim about a past this
/// process never saw.
///
/// A peek: it creates no engine and touches no idle clock, so polling it
/// cannot keep a torrent seeding to report on. It does list the stream's
/// own directories, so it blocks the FRB worker -- never call it from the
/// UI thread, and ask it only while a panel wants it. Errors when the
/// server is not running.
pub fn server_stream_numbers(url: String) -> anyhow::Result<Option<String>> {
    guarded(|| {
        crate::server::stream_numbers(&url)?
            .map(|numbers| serde_json::to_string(&numbers).map_err(Into::into))
            .transpose()
    })
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

/// Ends every proxied stream carrying `token` -- the name the app minted
/// for the player being torn down and put in the `/proxy` URL that player
/// fetches -- and answers how many streams that was.
///
/// An HLS player has several at once (a playlist and its segments all
/// carry the token, because the server writes it into every line of every
/// playlist it rewrites), and they all end together. A player that is not
/// being proxied has none, and answers 0.
///
/// **What it ends is the read and the token.** The body yields an error,
/// hyper drops the connection, and the demuxer sees its source fail now
/// rather than after `network-timeout`. Alone that would not end the
/// stream -- ffmpeg reconnects through the URL it already has, token and
/// all -- so the server retires the token at the same time and answers
/// `410 Gone` to anything bearing it afterwards. The order the server
/// documents is quit-then-close, because a demuxer that has already been
/// cancelled never reaches its reconnect; the refusal is what covers a
/// close that arrives first. A demuxer wedged somewhere else -- on the
/// Flutter texture, on the audio device -- is not waiting on this read and
/// is untouched by it.
///
/// 0 covers a finished player, an unproxied one and a server that is not
/// running alike, all of which mean there is nothing of this player left
/// to close. It is not, however, infallible: like every function here it
/// is wrapped in the panic guard, so a panic in the core crosses as an
/// `Err` and reaches Dart as a thrown exception. The caller is a
/// `dispose`, and it catches -- an unhandled throw there would skip the
/// release of the player itself.
///
/// Synchronous, and deliberately so: it is a map scan with no I/O, and it
/// is called from a teardown, where waiting for a place in the FRB worker
/// pool behind a blocking call (a stats poll, a cache walk) would give
/// back exactly the delay it exists to remove.
#[frb(sync)]
pub fn server_close_proxy_streams(token: String) -> anyhow::Result<i64> {
    guarded_ok(|| i64::try_from(crate::server::close_proxy_streams(&token)).unwrap_or(i64::MAX))
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

/// How many requests the LAN media listener has been asked for since it last
/// started -- per cast session, since a start and a stop both reset it. Zero
/// when nothing is listening, and zero for the next receiver rather than
/// whatever the last one ran up.
///
/// What it is for is telling a receiver that never fetched the stream from
/// one that did. Those look identical from the sofa (both are a splash
/// screen that never becomes a film) and identical to the sender, because a
/// receiver told an address it cannot route to hangs on the connect rather
/// than reporting an error. Zero well after a load means the address was
/// wrong; non-zero means the receiver reached this device, and that is the
/// whole of it -- whether one that reached us is filling a buffer or cannot
/// decode what it fetched is not something this number knows, since a cold
/// torrent twenty seconds in has necessarily made requests and is
/// necessarily still warming up.
///
/// Signed, because `u64` crosses FRB as a Dart `BigInt` and this is a number
/// the player compares against zero on a timer; `i64` crosses as a plain
/// `int`. A session that served more than nine quintillion requests reads as
/// `i64::MAX`, which says the same thing about the network as the true
/// figure would.
///
/// One relaxed atomic load, so it is synchronous and cheap enough to poll.
#[frb(sync)]
pub fn server_lan_media_requests_served() -> anyhow::Result<i64> {
    guarded_ok(|| i64::try_from(crate::server::lan_media_requests_served()).unwrap_or(i64::MAX))
}

/// The base URL to give a receiver at `peer_ip` (`"http://192.168.1.20:39271/"`),
/// so a media URL built on it names an interface that receiver can connect
/// back to -- the one sharing the receiver's subnet, since the first
/// interface on a host with a VPN or a container bridge regularly is not.
///
/// `peer_ip` is null when the receiver's address is not known. The answer is
/// then the best-ranked interface the server can offer for a peer it cannot
/// place on any subnet -- a private address on an ordinary interface ahead
/// of anything on one a receiver cannot be behind at all: a tunnel, a
/// cellular link, a tether, a container or VM bridge -- which is a guess, and
/// a guess a receiver on a home network can usually act on. It is a
/// parameter, and not simply left out, because a receiver whose address *is*
/// known deserves the answer that is not a guess at all.
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
