import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../core/core.dart';
import '../addons/addons_screen.dart';
import '../dev/dev_streams.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../diagnostics/server_storage_screen.dart';
import '../downloads/download_labels.dart';
import '../downloads/downloads_screen.dart';
import '../player/player_screen.dart';
import 'account_section.dart';
import 'core_settings.dart';

/// Settings: the account ([AccountSection] over `ctx.profile`), the ways to
/// the Addons and Downloads screens, the controls over
/// `ctx.profile.settings` (Player,
/// Subtitles, Interface, Streaming server; every change is one
/// `UpdateSettings` with the whole map and that key changed), the state of
/// the streaming server (from the `streaming_server` model field) and the
/// core.
///
/// Nothing here draws a focus indicator of its own. Every control is a
/// Material one on the app's own surface, so what marks the row the remote
/// is on is the theme floor (`FocusTheme`), which fills it -- and
/// deliberately only that: a settings row that grew and cast a shadow as
/// the D-pad walked a screenful of them would overlap the rows above and
/// below it on every press, which is the reason `FocusTreatment` has two
/// values.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.dhtStatus});

  /// Where the Peer discovery row's [DhtStatus] comes from (absent,
  /// `ServerClient().dhtStatus`) -- a plain function, the way
  /// `PlaybackScope.dhtStatus` is, so a widget test can hand over one that
  /// returns a chosen state or throws instead of reaching FFI.
  final DhtStatus Function()? dhtStatus;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// `SettingsScreen.dhtStatus`'s default: the embedded server over FFI.
DhtStatus _defaultDhtStatus() => const ServerClient().dhtStatus;

class _SettingsScreenState extends State<SettingsScreen> {
  CoreFieldNotifier? _server;
  CoreFieldNotifier? _ctx;

  /// The DHT's status, read alongside the streaming-server row above it --
  /// the same `NewState`-triggered pull [_server] already does, never a
  /// timer of its own. Null both before the first pull lands and whenever
  /// the read itself throws; either way the row shows a quiet "Unknown"
  /// rather than an error.
  DhtStatus? _dht;

  /// Every value a control has sent in `UpdateSettings` that no `ctx` pull
  /// has shown yet, by key. Laid over the settings the pull brought, it is
  /// what the controls show and what the next write builds on, so two
  /// changes in a row do not send the pre-first-change map.
  ///
  /// A value goes when a pull shows it, and not merely when a pull lands:
  /// a pull asked for before the `UpdateSettings` was handled answers the
  /// settings from before it, and taken as the authority it snapped the
  /// control back and had the next change send the old value again.
  final Map<String, Object?> _unconfirmed = {};

  /// The app's own preferences, for "Buffer ahead". From the [PrefsScope]
  /// the app puts above every screen; a screen mounted without one (a widget
  /// test that does not care where the choice goes) gets [_ownPrefs], which
  /// persists nothing.
  AppPrefs? _prefsOrNull;
  AppPrefs? _ownPrefs;

  AppPrefs get _prefs => _prefsOrNull!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_server?.client != client) {
      _server?.dispose();
      _ctx?.removeListener(_onCtx);
      _ctx?.dispose();
      _server = CoreFieldNotifier(client, CoreField.streamingServer)
        ..addListener(_onServer);
      _ctx = CoreFieldNotifier(client, CoreField.ctx)..addListener(_onCtx);
    }
    // Reading the scope here is what subscribes to it, so a choice changed
    // in the player is already shown when this screen comes back.
    final prefs =
        PrefsScope.maybeOf(context) ?? (_ownPrefs ??= AppPrefs.inMemory());
    if (_prefsOrNull != prefs) {
      _prefsOrNull?.removeListener(_onPrefs);
      _prefsOrNull = prefs..addListener(_onPrefs);
    }
  }

  void _onPrefs() {
    if (mounted) setState(() {});
  }

  /// A `ctx` pull landed: what it shows of the values sent is confirmed,
  /// and the engine is the authority for those again.
  void _onCtx() {
    if (!mounted || _unconfirmed.isEmpty) return;
    final landed = _settingsOf(_ctx?.value)?.json;
    if (landed == null) return;
    final confirmed = [
      for (final MapEntry(:key, :value) in _unconfirmed.entries)
        if (_shows(key, landed[key], value)) key,
    ];
    if (confirmed.isEmpty) return;
    setState(() => confirmed.forEach(_unconfirmed.remove));
  }

  /// Whether a pull's [landed] value for [key] is the [sent] one, as the
  /// engine keeps it. The server URL comes back as stremio-core's `Url`,
  /// with a slash on one typed without a path: compared as strings, the
  /// URL sent was never let go, so the screen showed it over whatever the
  /// engine held from then on and every later change sent it back.
  static bool _shows(String key, Object? landed, Object? sent) {
    if (landed == sent) return true;
    return key == ProfileSettings.streamingServerUrlKey &&
        landed is String &&
        sent is String &&
        StreamingServerSection.sameUrl(landed, sent);
  }

  /// The streaming-server field pulled (or failed to): piggyback the DHT
  /// read on that same trigger rather than giving it a poll of its own.
  void _onServer() {
    DhtStatus? dht;
    try {
      dht = (widget.dhtStatus ?? _defaultDhtStatus)();
    } catch (_) {
      dht = null;
    }
    if (mounted) setState(() => _dht = dht);
  }

  @override
  void dispose() {
    _server?.removeListener(_onServer);
    _server?.dispose();
    _ctx?.removeListener(_onCtx);
    _ctx?.dispose();
    _prefsOrNull?.removeListener(_onPrefs);
    _ownPrefs?.dispose();
    super.dispose();
  }

  /// The profile settings of the `ctx` state, or null while unknown.
  static ProfileSettings? _settingsOf(Map<String, dynamic>? ctx) {
    if (ctx == null) return null;
    final settings = ProfileState.fromCtx(ctx).settings;
    return settings.isEmpty ? null : settings;
  }

  /// One setting changed: `UpdateSettings` with the whole map, as the
  /// engine has no per-field defaults; the value is [_unconfirmed] until a
  /// pull shows it.
  void _updateSetting(ProfileSettings settings, String key, Object? value) {
    final next = settings.withValue(key, value);
    setState(() => _unconfirmed[key] = value);
    CoreScope.of(context).dispatch(CoreActions.updateSettings(next));
  }

  /// [build] over the current settings, or the pending indicator until the
  /// `ctx` field has arrived (no control may write a partial map).
  Widget _withSettings(
    Widget Function(ProfileSettings settings, SettingWriter write) build,
  ) => ValueListenableBuilder<Map<String, dynamic>?>(
    valueListenable: _ctx!,
    builder: (context, ctx, _) {
      final landed = _settingsOf(ctx);
      if (landed == null) return const _SettingsPending();
      final settings = _unconfirmed.isEmpty
          ? landed
          : ProfileSettings({...landed.json, ..._unconfirmed});
      return build(
        settings,
        (key, value) => _updateSetting(settings, key, value),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final initInfo = CoreScope.initInfoOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        // The default cache extent (250px) only pre-builds a couple of
        // screens' worth around the viewport; a D-pad's directional focus
        // move only ever considers *built* widgets, so a jump from one
        // focusable tile, over several informational rows with no `onTap`
        // (Status, Peer discovery, the core-schema line), to the next
        // focusable one below (Diagnostics) can land on nothing at all if
        // that next tile has not been built yet. This screen's whole
        // content is short and fixed, so building generously ahead costs
        // nothing.
        scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
        children: [
          const _SectionHeader('Account'),
          AccountSection(ctx: _ctx!),
          const _SectionHeader('Addons'),
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: const Text('Addons'),
            subtitle: const Text('Installed and community addons'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AddonsScreen()),
            ),
          ),
          const _SectionHeader('Downloads'),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Downloads'),
            // Not "and where": a download has no place of its own, and the
            // one root every torrent byte is under is named and moved in
            // Server storage below.
            subtitle: const Text('Titles kept on this device'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(DownloadsScreen.route()),
          ),
          const _SectionHeader('Player'),
          // Not a `profile.settings` field, so it is outside `_withSettings`
          // and shows whether or not the `ctx` field has arrived.
          BufferAheadSection(prefs: _prefs),
          _withSettings(
            (settings, write) =>
                PlayerSettingsSection(settings: settings, onSetting: write),
          ),
          const _SectionHeader('Subtitles'),
          _withSettings(
            (settings, write) =>
                SubtitlesSettingsSection(settings: settings, onSetting: write),
          ),
          const _SectionHeader('Interface'),
          // The app's own preference, and a television's only, so it is
          // outside `_withSettings` like "Buffer ahead" above.
          FocusEmphasisSection(prefs: _prefs),
          _withSettings(
            (settings, write) =>
                InterfaceSettingsSection(settings: settings, onSetting: write),
          ),
          const _SectionHeader('Streaming server'),
          _withSettings(
            (settings, write) => StreamingServerSection(
              settings: settings,
              embeddedUrl: initInfo?.serverBaseUrl,
              onSetting: write,
            ),
          ),
          // The app's own preference again, so it is outside `_withSettings`
          // like "Buffer ahead": what it feeds is the embedded server's
          // `seedingEnabled`, not a `profile.settings` field, and the
          // policy that sends it reads the preferences directly.
          IdleSharingSection(prefs: _prefs),
          ValueListenableBuilder<Map<String, dynamic>?>(
            valueListenable: _server!,
            builder: (context, state, _) {
              final settings = state?['settings'] as Map<String, dynamic>?;
              final status = _server!.lastError != null
                  ? 'Unavailable (${_server!.lastError})'
                  : switch (settings?['type']) {
                      'Ready' => 'Ready',
                      'Loading' => 'Connecting…',
                      'Err' => 'Error: ${settings?['content']}',
                      _ => 'Unknown',
                    };
              final url = state?['baseUrl'] as String?;
              return ListTile(
                leading: Icon(
                  settings?['type'] == 'Ready'
                      ? Icons.check_circle_outline
                      : Icons.hourglass_empty,
                ),
                title: const Text('Status'),
                subtitle: Text(url == null ? status : '$status · $url'),
              );
            },
          ),
          // Where the bytes go, what they cost and the one way to ask for
          // room back -- one root and one screen for all of it, which is
          // why this is here and not among the developer tools it used to
          // sit with: moving it is an ordinary thing to want.
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: const Text('Server storage'),
            subtitle: const Text(
              'Where torrent data lives, what it costs, and a clean-now',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ServerStorageScreen(),
              ),
            ),
          ),
          // Directly under the server's own status: the DHT is a peer
          // *source* for that server, not a requirement (a torrent with
          // working trackers downloads fine without one), so this shows
          // health in both directions -- a bootstrapped DHT's node count
          // and a never-bootstrapped one's plain explanation -- rather
          // than only ever flagging a fault. `DhtStatus.healthLine` is the
          // one place the wording lives; Diagnostics reads the same
          // `unavailableMessage` constant it composes with.
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('Peer discovery'),
            subtitle: Text(_dht?.healthLine ?? 'Unknown'),
          ),
          const _SectionHeader('Core'),
          ListTile(
            leading: const Icon(Icons.memory_outlined),
            title: const Text('stremio-core storage schema'),
            subtitle: Text(
              initInfo == null ? 'unknown' : 'v${initInfo.schemaVersion}',
            ),
          ),
          const _SectionHeader('Developer'),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Diagnostics'),
            subtitle: const Text('Recent logs, and a copy button for them'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DiagnosticsScreen(),
              ),
            ),
          ),
          const _DevPlayTile(
            icon: Icons.cloud_download_outlined,
            title: 'Play test torrent',
            stream: DevStreams.bigBuckBunnyTorrent,
          ),
          const _DevPlayTile(
            icon: Icons.link,
            title: 'Play test HTTP stream',
            stream: DevStreams.bigBuckBunnyHttp,
          ),
          const _DevDownloadTile(),
        ],
      ),
    );
  }
}

/// Plays a hand-built stream through the same core Player path an addon
/// stream takes, so playback can be proven without any addon. Ships in
/// release builds: it is how the owner reproduces a playback failure on the
/// device it happened on. The content is public-domain test footage and the
/// tile says so.
class _DevPlayTile extends StatelessWidget {
  const _DevPlayTile({
    required this.icon,
    required this.title,
    required this.stream,
  });

  final IconData icon;
  final String title;
  final Map<String, dynamic> stream;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text('${stream['name']} · ${stream['description']}'),
    trailing: const Icon(Icons.play_arrow),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: PlayerScreen.routeName),
        builder: (_) => PlayerScreen(stream: stream),
      ),
    ),
  );
}

/// Keeps the test torrent on the device through the same `DownloadsClient`
/// a stream tile's download button uses, so the download path can be proven
/// on a device with no addon installed. The entry lands in the registry
/// under a meta id of its own, which is also what removes it again from the
/// Downloads screen -- with the same confirmation every other removal asks
/// for, which is why this is safe to ship.
class _DevDownloadTile extends StatelessWidget {
  const _DevDownloadTile();

  /// What the entry is keyed by: a hand-built stream belongs to no meta, so
  /// it names itself.
  static const String metaId = 'dev:bigbuckbunny';

  static const String title = 'Download test torrent';

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.download_outlined),
    title: const Text(title),
    subtitle: const Text('Keeps the public torrent on this device'),
    trailing: const Icon(Icons.download),
    onTap: () => _start(context),
  );

  /// The same call the download button makes, with the little the dev
  /// stream knows about itself: no meta snapshot and no addon requests, so
  /// the row renders and plays but records no library progress.
  Future<void> _start(BuildContext context) async {
    final client = DownloadsScope.maybeOf(context);
    if (client == null) return;
    final messenger = ScaffoldMessenger.of(context);
    DownloadAddResult? result;
    Object? thrown;
    try {
      result = await client.add(
        DownloadRequest(
          metaId: metaId,
          videoId: metaId,
          type: 'movie',
          name: DevStreams.bigBuckBunnyTorrent['name'] as String,
          stream: StreamInfo(DevStreams.bigBuckBunnyTorrent),
        ),
      );
    } catch (error) {
      thrown = error;
    }
    final failure = result?.error;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          thrown != null
              ? 'The test download could not be started.'
              : failure != null
              ? downloadFailureMessage(failure)
              : 'Downloading the test torrent.',
        ),
      ),
    );
  }
}

/// Shown in place of a settings section until the `ctx` field is in (a
/// moment after start-up). Deliberately static: nothing here animates.
class _SettingsPending extends StatelessWidget {
  const _SettingsPending();

  @override
  Widget build(BuildContext context) => const ListTile(
    leading: Icon(Icons.hourglass_empty),
    title: Text('Loading settings…'),
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}
