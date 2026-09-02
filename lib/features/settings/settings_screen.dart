import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../addons/addons_screen.dart';
import '../dev/dev_streams.dart';
import '../player/player_screen.dart';
import 'account_section.dart';

/// Settings: the account ([AccountSection] over `ctx.profile`), the way to
/// the Addons screen, the state of the embedded streaming server and the
/// core (straight from the `streaming_server` model field).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  CoreFieldNotifier? _server;
  CoreFieldNotifier? _ctx;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_server?.client != client) {
      _server?.dispose();
      _ctx?.dispose();
      _server = CoreFieldNotifier(client, CoreField.streamingServer);
      _ctx = CoreFieldNotifier(client, CoreField.ctx);
    }
  }

  @override
  void dispose() {
    _server?.dispose();
    _ctx?.dispose();
    super.dispose();
  }

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
          const _SectionHeader('Streaming server'),
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
              final url =
                  state?['baseUrl'] as String? ??
                  initInfo?.serverBaseUrl?.toString() ??
                  'not running';
              return Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: const Text('Embedded server'),
                    subtitle: Text(url),
                  ),
                  ListTile(
                    leading: Icon(
                      settings?['type'] == 'Ready'
                          ? Icons.check_circle_outline
                          : Icons.hourglass_empty,
                    ),
                    title: const Text('Status'),
                    subtitle: Text(status),
                  ),
                ],
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
