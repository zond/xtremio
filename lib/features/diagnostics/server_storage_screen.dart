import 'dart:io' show Directory, Platform;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/core.dart';
import '../../widgets/tv_text_field.dart';

/// The directories this platform can offer as a torrent-data root. On
/// Android those are the app's own external storage directories, an SD card
/// among them -- permission-free on `minSdk` 24, and the only way to reach
/// a card without one; everywhere else there are none to enumerate and a
/// path is typed instead.
Future<List<String>> platformDataRoots() async {
  if (!Platform.isAndroid) return const [];
  final roots = await getExternalStorageDirectories();
  return [for (final root in roots ?? const <Directory>[]) root.path];
}

/// Where the embedded server puts torrent data, what that costs, and the
/// one way there is to ask it to reclaim some.
///
/// This is the first screen to look at when the cache is well past its
/// limit: the same cache-vs-limit number is in the copied diagnostics
/// header (alongside the device's free space, which lives there and not
/// here); this is where it can be watched and acted on. There is no
/// scheduled sweep behind it. The server's torrent engine and proxy cache
/// each give back what nobody is playing and nobody kept as they go, and
/// Clean now asks both for that slack at once. It never stops playback, so
/// the action needs no confirmation.
///
/// **What is never taken** is a kept download, and the window around the
/// playhead of the title played last -- which stays kept after the player
/// closes, until something else is played. The text here says so rather
/// than "a live stream": the case it has to explain is a clean that frees
/// nothing with the player shut.
///
/// **There is one root**, `cacheRoot`, and everything a torrent puts on
/// this device is under it: the piece store the streaming cache and the
/// kept downloads share, the session's own records, and what the proxy
/// cached. So it is named here, beside the size it is held to, rather
/// than on the Downloads screen -- a download has no location of its own
/// to be moved to.
///
/// A copy button, a clean-now button and rows, all on the app's own
/// surface: the theme floor marks every one of them and this screen adds
/// nothing, the same decision [SettingsScreen] explains.
class ServerStorageScreen extends StatefulWidget {
  const ServerStorageScreen({
    super.key,
    this.client = const ServerClient(),
    this.roots = platformDataRoots,
  });

  /// Where the numbers come from and what a clean is asked of; widget
  /// tests hand over a fake rather than reaching a real server.
  final ServerCacheControl client;

  /// The directories to offer as a root; empty means a path is typed.
  final Future<List<String>> Function() roots;

  /// Heading of the root control.
  static const String rootTitle = 'Where torrent data lives';

  /// What a root that took says. The running torrent session was opened on
  /// the old one and cannot be moved onto this, so the change is real and
  /// its effect is not, until the app is started again.
  static String movedMessage(String path) =>
      'Torrent data goes to $path from the next start.';

  /// ... and what a root the server refused says.
  static const String refusedMessage =
      'That folder cannot be used for torrent data.';

  @override
  State<ServerStorageScreen> createState() => _ServerStorageScreenState();
}

class _ServerStorageScreenState extends State<ServerStorageScreen> {
  CacheUsage? _usage;
  ServerStorage? _storage;
  String? _error;
  bool _busy = false;

  /// The roots to choose between; empty means a path is typed.
  List<String> _roots = const [];

  final TextEditingController _typed = TextEditingController();

  @override
  void initState() {
    super.initState();
    _read();
    _readRoots();
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  /// What this platform can offer. Failing is not worth an error on
  /// screen: without the choices the control is a text field.
  Future<void> _readRoots() async {
    List<String> roots;
    try {
      roots = await widget.roots();
    } catch (_) {
      roots = const [];
    }
    if (!mounted) return;
    setState(() => _roots = roots);
  }

  /// Points `cacheRoot` at [path]. The server validates it -- absolute,
  /// creatable, writable -- and a root it refuses fails the whole update,
  /// so nothing here has to check a path itself.
  Future<void> _setRoot(String path) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final settings = await widget.client.updateSettings({'cacheRoot': path});
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            ServerStorageScreen.movedMessage(
              settings['cacheRoot'] as String? ?? path,
            ),
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text(ServerStorageScreen.refusedMessage)),
      );
    }
    if (!mounted) return;
    await _read();
  }

  /// Reads [CacheUsage]. Called on open, after a clean and on an explicit
  /// refresh -- never on a timer: it is two worker calls into the server,
  /// and nothing on this screen moves fast enough to need more.
  Future<void> _read() async {
    setState(() => _busy = true);
    try {
      final usage = await widget.client.cacheUsage();
      // The root and its volume, from the same read: a number is only
      // about a directory, and this screen is where that directory is.
      final storage = await widget.client.storage();
      if (!mounted) return;
      setState(() {
        _usage = usage;
        _storage = storage;
        _typed.text = storage.cacheDir;
        _error = null;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _usage = null;
        _storage = null;
        _error = '$error';
        _busy = false;
      });
    }
  }

  /// Asks the server for its slack and reports honestly what happened:
  /// bytes freed when something was given back, and -- when the cache is
  /// still over its limit afterwards -- that a kept download or the title
  /// played last is holding what is left, never "clean failed" (nothing
  /// here can fail short of the server not running).
  Future<void> _clean() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final report = await widget.client.cleanCacheNow();
      messenger.showSnackBar(SnackBar(content: Text(_cleanMessage(report))));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not clean: $error')),
      );
    }
    if (!mounted) return;
    await _read();
  }

  String _cleanMessage(EvictionReport report) {
    if (report.freed > 0) {
      final files = report.deleted == 1 ? 'file' : 'files';
      return 'Freed ${DownloadView.humanSize(report.freed)} '
          'from ${report.deleted} $files.';
    }
    if (report.stillOverLimit) {
      return 'Nothing more can be freed right now -- a download you kept '
          'or the title you played last is holding '
          '${DownloadView.humanSize(report.protected)}.';
    }
    return 'Nothing needed cleaning.';
  }

  @override
  Widget build(BuildContext context) {
    final usage = _usage;
    final storage = _storage;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Server storage'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _read,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (usage == null)
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('Storage unavailable'),
              subtitle: Text(_error ?? 'Reading…'),
            )
          else
            _Row(
              icon: Icons.folder_outlined,
              title: 'Torrent cache',
              value: usage.label,
              detail: usage.protectedFiles > 0
                  ? '${DownloadView.humanSize(usage.protectedBytes)} in '
                        '${usage.protectedFiles} '
                        '${usage.protectedFiles == 1 ? 'file' : 'files'} '
                        'kept: a download, or the title played last'
                  : 'Nothing protected right now',
              warning: usage.overLimit
                  ? (usage.nothingEvictable
                        ? 'Over its limit, and nothing is evictable right '
                              'now.'
                        : 'Over its limit.')
                  : null,
            ),
          if (storage != null) ...[
            const Divider(height: 24),
            _DataRoot(
              root: storage.cacheDir,
              volume: storage.cacheVolume.label,
              choices: _roots,
              typed: _typed,
              enabled: !_busy,
              onSelect: _setRoot,
            ),
          ],
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _busy || usage == null ? null : _clean,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('Clean cache now'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'The server gives back what nobody is playing and nobody '
              'kept by itself, as it goes. Cleaning now asks for that at '
              'once, without stopping anything that is playing. A download '
              'you kept is never touched, and neither is the part of the '
              'title you played last around where you were, until you play '
              'something else.',
            ),
          ),
        ],
      ),
    );
  }
}

/// The one directory every torrent byte on this device is under, and the
/// way to move it.
///
/// A choice of directories where the platform has them (Android, where an
/// SD card is only reachable this way), a typed path where it does not.
/// Nothing here validates: the server does, and refuses the whole update
/// for a root it cannot use.
class _DataRoot extends StatelessWidget {
  const _DataRoot({
    required this.root,
    required this.volume,
    required this.choices,
    required this.typed,
    required this.enabled,
    required this.onSelect,
  });

  final String root;
  final String volume;
  final List<String> choices;
  final TextEditingController typed;
  final bool enabled;
  final ValueChanged<String> onSelect;

  /// Why the row a change writes is not yet the directory the bytes are
  /// in. The torrent session was opened on the old root at start-up and
  /// librqbit cannot be moved onto another one while it runs.
  static const String takesEffectNextStart =
      'The streaming cache and everything kept offline live here, as one '
      'file per piece. A new folder takes effect the next time the app '
      'starts: the torrent session running now was opened on the old one, '
      'and what is already there is not moved.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ServerStorageScreen.rootTitle,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(root, style: theme.textTheme.bodyLarge),
          Text(volume, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          if (choices.isEmpty)
            TvTextField(
              controller: typed,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                labelText: 'Folder',
                hintText: '/media/torrents',
              ),
              onSubmitted: _submit,
            )
          else
            for (final choice in choices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  choice == root
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(choice),
                enabled: enabled && choice != root,
                onTap: () => _submit(choice),
              ),
          if (choices.isEmpty) ...[
            const SizedBox(height: 8),
            FilledButton(
              onPressed: enabled ? () => _submit(typed.text) : null,
              child: const Text('Use this folder'),
            ),
          ],
          const SizedBox(height: 8),
          Text(takesEffectNextStart, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  void _submit(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty || trimmed == root) return;
    onSelect(trimmed);
  }
}

/// One number with what it means under it.
class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.value,
    required this.detail,
    this.warning,
  });

  final IconData icon;
  final String title;
  final String value;
  final String detail;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = this.warning;
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: theme.textTheme.bodyLarge),
          Text(detail, style: theme.textTheme.bodySmall),
          if (warning != null)
            Text(
              warning,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}
