import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/units.dart';
import '../../shell/external_link.dart';
import '../../widgets/readout.dart';
import 'apk_download.dart';
import 'apk_installer.dart';
import 'app_updates.dart';
import 'releases.dart';

/// Puts [release] to the viewer: what it is, what changed, and Update,
/// Skip this version or Later.
///
/// Update installs it where [AppUpdates.canInstall] (an Android release
/// build) and opens its page everywhere else. Nothing is installed without
/// a press here *and* Android's own confirmation after it.
Future<void> showUpdateDialog(
  BuildContext context, {
  required AppUpdates updates,
  required ReleaseInfo release,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => UpdateDialog(updates: updates, release: release),
);

/// Where an update is between the offer and Android's confirmation.
enum _Step { offer, downloading, permission, installing, failed }

/// The dialog [showUpdateDialog] shows. One dialog for the whole way, so a
/// remote's focus never has to find its way to a second one: each step
/// replaces the content and puts focus on its first button.
///
/// On a television the notes are a [Readout], so the remote can walk up
/// into them from the buttons and read a long one a screenful at a time;
/// the buttons are what focus starts on.
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.updates, required this.release});

  final AppUpdates updates;
  final ReleaseInfo release;

  static const String updateLabel = 'Update';
  static const String openPageLabel = 'Open release page';
  static const String skipLabel = 'Skip this version';
  static const String laterLabel = 'Later';
  static const String cancelLabel = 'Cancel';
  static const String closeLabel = 'Close';
  static const String retryLabel = 'Try again';
  static const String openSettingsLabel = 'Open settings';
  static const String installLabel = 'Install';

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  _Step _step = _Step.offer;

  /// The device's first ABI and the asset for it, once asked; the asset is
  /// null for an ABI the release has no build for.
  String? _abi;
  ReleaseAsset? _asset;
  bool _abiAsked = false;

  int _received = 0;
  int _total = 0;
  ApkDownloader? _downloader;
  String? _apkPath;

  /// What went wrong, for [_Step.failed].
  String _failure = '';

  /// Whether the "Install unknown apps" shortcut opened; false shows where
  /// the setting is instead.
  bool? _settingsOpened;

  /// The notes' stop on a television; see [_onKey].
  final FocusNode _notes = FocusNode(debugLabel: 'update notes');

  AppUpdates get _updates => widget.updates;
  ReleaseInfo get _release => widget.release;

  @override
  void initState() {
    super.initState();
    if (_updates.canInstall) unawaited(_askAbi());
  }

  Future<void> _askAbi() async {
    String? abi;
    try {
      abi = await _updates.installer.primaryAbi();
    } catch (_) {
      abi = null;
    }
    if (!mounted) return;
    setState(() {
      _abiAsked = true;
      _abi = abi;
      final name = abi == null ? null : apkAssetNameForAbi(abi);
      _asset = name == null ? null : _release.asset(name);
    });
  }

  /// Installs rather than pointing at the page: the build may, and the
  /// release has a file for this device.
  bool get _installs => _updates.canInstall && _asset != null;

  @override
  void dispose() {
    _notes.dispose();
    _downloader?.cancel();
    super.dispose();
  }

  Future<void> _openPage() async {
    final opener = ExternalLinkScope.of(context);
    Navigator.of(context).pop();
    await opener.open(_release.page);
  }

  Future<void> _skip() async {
    Navigator.of(context).pop();
    await _updates.skip(_release);
  }

  Future<void> _download() async {
    final asset = _asset;
    final abi = _abi;
    if (asset == null || abi == null) return;
    final downloader = _downloader = _updates.newDownloader();
    setState(() {
      _step = _Step.downloading;
      _received = 0;
      _total = asset.size;
    });
    try {
      final file = await downloader.download(
        url: asset.url,
        target: await _updates.apkFile(_release, abi),
        digest: asset.digest,
        expectedSize: asset.size,
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              _received = received;
              _total = total;
            });
          }
        },
      );
      _apkPath = file.path;
    } on UpdateDownloadException catch (error) {
      _fail(error.message);
      return;
    } catch (error) {
      _fail('The download failed (${error.runtimeType}).');
      return;
    } finally {
      if (identical(_downloader, downloader)) _downloader = null;
    }
    if (!mounted) return;
    bool allowed;
    try {
      allowed = await _updates.installer.canRequestInstalls();
    } catch (_) {
      allowed = false;
    }
    if (!mounted) return;
    if (allowed) {
      await _install();
    } else {
      setState(() {
        _step = _Step.permission;
        _settingsOpened = null;
      });
    }
  }

  Future<void> _openInstallSettings() async {
    bool opened;
    try {
      opened = await _updates.installer.openInstallPermission();
    } catch (_) {
      opened = false;
    }
    if (mounted) setState(() => _settingsOpened = opened);
  }

  Future<void> _install() async {
    final path = _apkPath;
    if (path == null) return;
    setState(() => _step = _Step.installing);
    final outcome = await _updates.installer.install(path);
    if (!mounted) return;
    if (outcome.result == InstallResult.success) {
      Navigator.of(context).pop();
      return;
    }
    _fail(installFailureText(outcome));
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _step = _Step.failed;
      _failure = message;
    });
  }

  /// Again from where it went wrong: an install that failed is installed
  /// again, a download is picked up where it stopped.
  void _retry() => _apkPath == null ? _download() : _install();

  /// Up from the buttons into the notes, on a television.
  ///
  /// Flutter's directional traversal would not: it moves to a stop whose
  /// *centre* is past the edge of the one it leaves, and notes longer than
  /// their viewport have their centre below the buttons. Down out of them
  /// needs nothing: the notes' own [Readout] walks them a screenful at a
  /// time and lets the press go only once their end is on screen, where
  /// the buttons are below it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _step != _Step.offer) {
      return KeyEventResult.ignored;
    }
    if (_notes.context == null) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
        !_notes.hasPrimaryFocus) {
      _notes.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // Back is Later while offering and Close after a failure; during a
    // download it is Cancel ([dispose] stops the download, which keeps its
    // part for the next attempt).
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      // Keyed by the step, so each step's buttons are new ones and the
      // first of them takes focus: a remote never has to look for it.
      child: AlertDialog(
        key: ValueKey((_step, _abiAsked, _settingsOpened)),
        title: Text(_title),
        content: SizedBox(width: 480, child: _content(context)),
        actions: _actions(context),
      ),
    );
  }

  String get _title => switch (_step) {
    _Step.offer => 'xtremio ${_release.version} is available',
    _Step.downloading => 'Downloading xtremio ${_release.version}',
    _Step.permission => 'Allow xtremio to install apps',
    _Step.installing => 'Installing xtremio ${_release.version}',
    _Step.failed => 'The update did not install',
  };

  Widget _content(BuildContext context) => switch (_step) {
    _Step.offer => _offer(context),
    _Step.downloading => _progress(context),
    _Step.permission => _permission(),
    _Step.installing => const Text(
      'Confirm the install on Android\'s screen. When it is done Android '
      'closes xtremio; open it again to use the new version.',
    ),
    _Step.failed => Text(_failure),
  };

  Widget _offer(BuildContext context) {
    final current = _updates.identity.parsed;
    final notes = releaseNotesText(_release.notes);
    final note = switch ((_updates.canInstall, _abiAsked, _asset)) {
      (false, _, _) when _updates.installsHere =>
        'This is a debug build, a separate app from the release, so it '
            'cannot install the update. Install the release from its page.',
      (true, true, null) =>
        'This release has no build for this device'
            '${_abi == null ? '' : ' ($_abi)'}. Its page lists every file.',
      _ => null,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (current != null) Text('This is xtremio $current.'),
        if (note != null) ...[const SizedBox(height: 8), Text(note)],
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: Readout(focusNode: _notes, child: Text(notes)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _progress(BuildContext context) {
    final fraction = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 8),
        Text(
          _total > 0
              ? '${formatBytes(_received)} of ${formatBytes(_total)}'
              : formatBytes(_received),
        ),
      ],
    );
  }

  Widget _permission() => Text(switch (_settingsOpened) {
    false =>
      'This device has no shortcut to the setting. On a phone it is under '
          'Settings > Apps > Special app access > Install unknown apps > '
          'xtremio; on a television, usually Settings > Apps > Security & '
          'restrictions > Unknown sources. Or press Install: Android asks '
          'for the permission itself.',
    true =>
      'Turn on "Allow from this source" for xtremio, come back, and press '
          'Install.',
    null =>
      'Android lets an app install updates only with your permission. Open '
          'the setting and allow xtremio, then press Install. Android shows '
          'its own confirmation before anything is installed.',
  });

  List<Widget> _actions(BuildContext context) => switch (_step) {
    _Step.offer => [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text(UpdateDialog.laterLabel),
      ),
      TextButton(onPressed: _skip, child: const Text(UpdateDialog.skipLabel)),
      if (_updates.canInstall && !_abiAsked)
        const FilledButton(
          onPressed: null,
          child: Text(UpdateDialog.updateLabel),
        )
      else if (_installs)
        FilledButton(
          autofocus: true,
          onPressed: _download,
          child: const Text(UpdateDialog.updateLabel),
        )
      else
        FilledButton(
          autofocus: true,
          onPressed: _openPage,
          child: const Text(UpdateDialog.openPageLabel),
        ),
    ],
    _Step.downloading => [
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.of(context).pop(),
        child: const Text(UpdateDialog.cancelLabel),
      ),
    ],
    _Step.permission => [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text(UpdateDialog.cancelLabel),
      ),
      TextButton(
        autofocus: _settingsOpened == null,
        onPressed: _openInstallSettings,
        child: const Text(UpdateDialog.openSettingsLabel),
      ),
      FilledButton(
        autofocus: _settingsOpened != null,
        onPressed: _install,
        child: const Text(UpdateDialog.installLabel),
      ),
    ],
    _Step.installing => [
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.of(context).pop(),
        child: const Text(UpdateDialog.closeLabel),
      ),
    ],
    _Step.failed => [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text(UpdateDialog.closeLabel),
      ),
      if (_installs)
        FilledButton(
          autofocus: true,
          onPressed: _retry,
          child: const Text(UpdateDialog.retryLabel),
        ),
    ],
  };
}
