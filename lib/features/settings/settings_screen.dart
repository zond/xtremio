import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../addons/addons_screen.dart';
import '../dev/dev_streams.dart';
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
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DownloadsScreen()),
            ),
          ),
          const _SectionHeader('Player'),
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
          if (!kReleaseMode) ...[
            const _SectionHeader('Developer'),
            _DevPlayTile(
              icon: Icons.cloud_download_outlined,
              title: 'Play test torrent',
              stream: DevStreams.bigBuckBunnyTorrent,
            ),
            _DevPlayTile(
              icon: Icons.link,
              title: 'Play test HTTP stream',
              stream: DevStreams.bigBuckBunnyHttp,
            ),
          ],
        ],
      ),
    );
  }
}

/// Debug-only: plays a hand-built stream through the same core Player path
/// an addon stream takes, so playback can be proven without any addon.
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
    subtitle: Text(stream['description'] as String),
    trailing: const Icon(Icons.play_arrow),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'player'),
        builder: (_) => PlayerScreen(stream: stream),
      ),
    ),
  );
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
