import 'package:flutter/material.dart';

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
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  CoreFieldNotifier? _server;
  CoreFieldNotifier? _ctx;

  /// The settings map of the last `UpdateSettings` sent, until the next
  /// `ctx` pull: what the controls show and what the next write builds on,
  /// so two changes in a row do not send the pre-first-change map.
  Map<String, dynamic>? _pending;

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
      _server = CoreFieldNotifier(client, CoreField.streamingServer);
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

  /// A `ctx` pull landed: the engine's settings are the authority again.
  void _onCtx() {
    if (mounted && _pending != null) setState(() => _pending = null);
  }

  @override
  void dispose() {
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
  /// engine has no per-field defaults; the map sent is [_pending] until
  /// the engine reports back.
  void _updateSetting(ProfileSettings settings, String key, Object? value) {
    final next = settings.withValue(key, value);
    setState(() => _pending = next);
    CoreScope.of(context).dispatch(CoreActions.updateSettings(next));
  }

  /// [build] over the current settings, or the pending indicator until the
  /// `ctx` field has arrived (no control may write a partial map).
  Widget _withSettings(
    Widget Function(ProfileSettings settings, SettingWriter write) build,
  ) => ValueListenableBuilder<Map<String, dynamic>?>(
    valueListenable: _ctx!,
    builder: (context, ctx, _) {
      final pending = _pending;
      final settings = pending == null
          ? _settingsOf(ctx)
          : ProfileSettings(pending);
      if (settings == null) return const _SettingsPending();
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
            subtitle: const Text('Titles kept on this device, and where'),
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
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: const Text('Server storage'),
            subtitle: const Text(
              'What the cache costs against its limit, and a clean-now',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ServerStorageScreen(),
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
        settings: const RouteSettings(name: 'player'),
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
