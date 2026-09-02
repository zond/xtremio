import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../player/language_names.dart';
import '../player/playback_engine.dart';
import '../player/subtitle_color_chips.dart';

/// Settings → Player / Subtitles / Interface / Streaming server: the
/// controls over `profile.settings`.
///
/// Every control reports one `(key, value)` through a [SettingWriter]; the
/// screen turns that into `UpdateSettings` with the *whole* map and that key
/// changed (`ProfileSettings.withValue`), since stremio-core has no
/// per-field defaults. Settings are device-local: the API never sees them.
typedef SettingWriter = void Function(String key, Object? value);

/// The widget key of the control for one settings key.
Key settingKey(String key) => ValueKey('setting-$key');

/// Player: binge watching, the up-next countdown, the seek steps, pause on
/// minimize, hardware decoding, preferred audio and subtitles languages.
class PlayerSettingsSection extends StatelessWidget {
  const PlayerSettingsSection({
    super.key,
    required this.settings,
    required this.onSetting,
  });

  final ProfileSettings settings;
  final SettingWriter onSetting;

  /// `nextVideoNotificationDuration` choices, ms: disabled, then 5…90 s
  /// (stremio-web's list).
  static final List<int> nextVideoDurations = [
    0,
    for (var s = 5; s <= 90; s += 5) s * 1000,
  ];

  /// `seekTimeDuration` / `seekShortTimeDuration` choices, ms.
  static const List<int> seekDurations = [
    3000,
    5000,
    10000,
    15000,
    20000,
    30000,
  ];

  static String secondsLabel(int millis) =>
      millis == 0 ? 'Disabled' : '${millis ~/ 1000} s';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile(
          key: settingKey(ProfileSettings.bingeWatchingKey),
          secondary: const Icon(Icons.skip_next_outlined),
          title: const Text('Binge watching'),
          subtitle: const Text('Move on to the next episode when one ends'),
          value: settings.bingeWatching,
          onChanged: (value) =>
              onSetting(ProfileSettings.bingeWatchingKey, value),
        ),
        ChoiceTile<int>(
          setting: ProfileSettings.nextVideoNotificationDurationKey,
          icon: Icons.timer_outlined,
          title: 'Up-next countdown',
          subtitle: 'How long the next episode waits after this one ends',
          value: settings.nextVideoNotificationDuration,
          options: nextVideoDurations,
          label: secondsLabel,
          onSetting: onSetting,
        ),
        ChoiceTile<int>(
          setting: ProfileSettings.seekTimeDurationKey,
          icon: Icons.forward_10,
          title: 'Seek step',
          subtitle: 'Arrow keys and the seek buttons',
          value: settings.seekTimeDuration,
          options: seekDurations,
          label: secondsLabel,
          onSetting: onSetting,
        ),
        ChoiceTile<int>(
          setting: ProfileSettings.seekShortTimeDurationKey,
          icon: Icons.forward_5,
          title: 'Short seek step',
          subtitle: 'Shift + arrow keys',
          value: settings.seekShortTimeDuration,
          options: seekDurations,
          label: secondsLabel,
          onSetting: onSetting,
        ),
        SwitchListTile(
          key: settingKey(ProfileSettings.pauseOnMinimizeKey),
          secondary: const Icon(Icons.pause_circle_outline),
          title: const Text('Pause when minimised'),
          subtitle: const Text('Pause playback when the app is hidden'),
          value: settings.pauseOnMinimize,
          onChanged: (value) =>
              onSetting(ProfileSettings.pauseOnMinimizeKey, value),
        ),
        SwitchListTile(
          key: settingKey(ProfileSettings.hardwareDecodingKey),
          secondary: const Icon(Icons.memory),
          title: const Text('Hardware decoding'),
          subtitle: const Text('Applies to the next video that opens'),
          value: settings.hardwareDecoding,
          onChanged: (value) =>
              onSetting(ProfileSettings.hardwareDecodingKey, value),
        ),
        LanguageTile(
          setting: ProfileSettings.audioLanguageKey,
          icon: Icons.audiotrack_outlined,
          title: 'Preferred audio language',
          value: settings.audioLanguage,
          onSetting: onSetting,
        ),
        LanguageTile(
          setting: ProfileSettings.subtitlesLanguageKey,
          icon: Icons.subtitles_outlined,
          title: 'Preferred subtitles language',
          value: settings.subtitlesLanguage,
          onSetting: onSetting,
        ),
      ],
    );
  }
}

/// Subtitles: size and colours, the same values the player's own settings
/// sheet edits.
class SubtitlesSettingsSection extends StatelessWidget {
  const SubtitlesSettingsSection({
    super.key,
    required this.settings,
    required this.onSetting,
  });

  final ProfileSettings settings;
  final SettingWriter onSetting;

  static String sizeLabel(int percent) => '$percent %';

  @override
  Widget build(BuildContext context) {
    final style = SubtitleStyle.fromSettings(settings);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChoiceTile<int>(
          setting: ProfileSettings.subtitlesSizeKey,
          icon: Icons.format_size,
          title: 'Size',
          value: settings.subtitlesSize,
          options: SubtitleStyle.sizes,
          label: sizeLabel,
          onSetting: onSetting,
        ),
        ListTile(
          key: settingKey(ProfileSettings.subtitlesTextColorKey),
          leading: const Icon(Icons.format_color_text),
          title: const Text('Text colour'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SubtitleColorChips(
              colors: SubtitleStyle.textColors,
              selected: settings.subtitlesTextColor,
              padding: EdgeInsets.zero,
              onSelected: (hex) =>
                  onSetting(ProfileSettings.subtitlesTextColorKey, hex),
            ),
          ),
        ),
        ListTile(
          key: settingKey(ProfileSettings.subtitlesBackgroundColorKey),
          leading: const Icon(Icons.format_color_fill),
          title: const Text('Background'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SubtitleColorChips(
              colors: SubtitleStyle.backgroundColors,
              selected: settings.subtitlesBackgroundColor,
              padding: EdgeInsets.zero,
              onSelected: (hex) =>
                  onSetting(ProfileSettings.subtitlesBackgroundColorKey, hex),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            color: const Color(0xFF303030),
            child: Text(
              'Subtitle preview',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: style.fontSize * 0.6,
                color: style.color,
                backgroundColor: style.hasBackground
                    ? style.backgroundColor
                    : null,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Interface: quit on close (desktop), Esc leaving fullscreen, spoilers.
class InterfaceSettingsSection extends StatelessWidget {
  const InterfaceSettingsSection({
    super.key,
    required this.settings,
    required this.onSetting,
  });

  final ProfileSettings settings;
  final SettingWriter onSetting;

  /// Whether this is a desktop build (`quitOnClose` only means something
  /// where there is a window to close).
  static bool get isDesktop => switch (defaultTargetPlatform) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (isDesktop)
          SwitchListTile(
            key: settingKey(ProfileSettings.quitOnCloseKey),
            secondary: const Icon(Icons.close),
            title: const Text('Quit when the window closes'),
            subtitle: const Text(
              'Stored for later: closing the window always quits for now',
            ),
            value: settings.quitOnClose,
            onChanged: (value) =>
                onSetting(ProfileSettings.quitOnCloseKey, value),
          ),
        SwitchListTile(
          key: settingKey(ProfileSettings.escExitFullscreenKey),
          secondary: const Icon(Icons.fullscreen_exit),
          title: const Text('Esc leaves fullscreen'),
          value: settings.escExitFullscreen,
          onChanged: (value) =>
              onSetting(ProfileSettings.escExitFullscreenKey, value),
        ),
        SwitchListTile(
          key: settingKey(ProfileSettings.hideSpoilersKey),
          secondary: const Icon(Icons.visibility_off_outlined),
          title: const Text('Hide spoilers'),
          subtitle: const Text(
            'Stored for later: episode thumbnails and summaries are '
            'still shown',
          ),
          value: settings.hideSpoilers,
          onChanged: (value) =>
              onSetting(ProfileSettings.hideSpoilersKey, value),
        ),
      ],
    );
  }
}

/// Streaming server: the embedded stream-server (its URL as init reported
/// it, which is what a loopback `streamingServerUrl` is retargeted to) or a
/// remote one by URL. Choosing "Embedded" writes the embedded URL at once;
/// "Remote" shows the field and writes on Save, after validation.
class StreamingServerSection extends StatefulWidget {
  const StreamingServerSection({
    super.key,
    required this.settings,
    required this.embeddedUrl,
    required this.onSetting,
  });

  final ProfileSettings settings;

  /// `CoreInitInfo.serverBaseUrl`; null when no embedded server runs.
  final Uri? embeddedUrl;
  final SettingWriter onSetting;

  static const Key embeddedKey = ValueKey('setting-server-embedded');
  static const Key remoteKey = ValueKey('setting-server-remote');
  static const Key remoteUrlFieldKey = ValueKey('setting-server-url');
  static const Key saveRemoteUrlKey = ValueKey('setting-server-save');

  static const String invalidUrlMessage =
      'Enter an http:// or https:// URL, such as http://192.168.1.10:11470';

  /// Whether [settingUrl] names the embedded server: the same URL up to
  /// the trailing slash stremio-core's `Url` serialisation adds.
  static bool isEmbedded(String? settingUrl, Uri? embedded) {
    if (settingUrl == null || embedded == null) return false;
    final setting = Uri.tryParse(settingUrl);
    return setting != null && _normalize(setting) == _normalize(embedded);
  }

  static String _normalize(Uri url) =>
      url.replace(path: url.path.isEmpty ? '/' : url.path).toString();

  /// Why [text] is not a usable server URL, or null when it is.
  static String? validateRemoteUrl(String text) {
    final url = Uri.tryParse(text.trim());
    final ok =
        url != null &&
        (url.scheme == 'http' || url.scheme == 'https') &&
        url.host.isNotEmpty;
    return ok ? null : invalidUrlMessage;
  }

  @override
  State<StreamingServerSection> createState() => _StreamingServerSectionState();
}

class _StreamingServerSectionState extends State<StreamingServerSection> {
  final TextEditingController _url = TextEditingController();

  /// "Remote" was picked but no URL saved yet, so the field shows while the
  /// engine still points at the embedded server.
  bool _remotePicked = false;
  String? _error;

  bool get _embedded => StreamingServerSection.isEmbedded(
    widget.settings.streamingServerUrl,
    widget.embeddedUrl,
  );

  bool get _remote => _remotePicked || !_embedded;

  @override
  void initState() {
    super.initState();
    _syncField();
  }

  @override
  void didUpdateWidget(StreamingServerSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.streamingServerUrl !=
            widget.settings.streamingServerUrl ||
        oldWidget.embeddedUrl != widget.embeddedUrl) {
      _remotePicked = false;
      _syncField();
    }
  }

  /// The field shows the remote URL in force, nothing for the embedded one.
  void _syncField() {
    _url.text = _embedded ? '' : widget.settings.streamingServerUrl ?? '';
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _pick(bool? remote) {
    if (remote == null) return;
    if (remote) {
      setState(() => _remotePicked = true);
      return;
    }
    final embedded = widget.embeddedUrl;
    if (embedded == null) return;
    setState(() {
      _remotePicked = false;
      _error = null;
    });
    widget.onSetting(
      ProfileSettings.streamingServerUrlKey,
      embedded.toString(),
    );
  }

  void _save() {
    final text = _url.text.trim();
    final problem = StreamingServerSection.validateRemoteUrl(text);
    setState(() => _error = problem);
    if (problem != null) return;
    widget.onSetting(ProfileSettings.streamingServerUrlKey, text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final embedded = widget.embeddedUrl;
    final remote = _remote;
    final error = _error;
    return RadioGroup<bool>(
      groupValue: remote,
      onChanged: _pick,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RadioListTile<bool>(
            key: StreamingServerSection.embeddedKey,
            value: false,
            enabled: embedded != null,
            title: const Text('Embedded server'),
            subtitle: Text(embedded?.toString() ?? 'Not running'),
          ),
          RadioListTile<bool>(
            key: StreamingServerSection.remoteKey,
            value: true,
            title: const Text('Remote server'),
            subtitle: remote
                ? null
                : const Text('A stream-server or Stremio service elsewhere'),
          ),
          if (remote)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: StreamingServerSection.remoteUrlFieldKey,
                          controller: _url,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Server URL',
                            hintText: 'http://192.168.1.10:11470',
                          ),
                          onSubmitted: (_) => _save(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.tonal(
                        key: StreamingServerSection.saveRemoteUrlKey,
                        onPressed: _save,
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A setting with a fixed list of values, as a dropdown on a tile. A
/// current value outside [options] is listed too, so the dropdown never
/// claims a value the profile does not hold.
class ChoiceTile<T> extends StatelessWidget {
  const ChoiceTile({
    super.key,
    required this.setting,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.options,
    required this.label,
    required this.onSetting,
  });

  /// The `Settings` key this tile edits.
  final String setting;
  final IconData icon;
  final String title;
  final String? subtitle;
  final T value;
  final List<T> options;
  final String Function(T value) label;
  final SettingWriter onSetting;

  @override
  Widget build(BuildContext context) {
    final items = options.contains(value) ? options : [...options, value];
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: DropdownButton<T>(
        key: settingKey(setting),
        value: value,
        underline: const SizedBox.shrink(),
        items: [
          for (final option in items)
            DropdownMenuItem<T>(value: option, child: Text(label(option))),
        ],
        onChanged: (selected) {
          if (selected != value) onSetting(setting, selected);
        },
      ),
    );
  }
}

/// An ISO 639-2 language setting: the player's default, or one of
/// [languageOptions] (plus whatever code the profile holds already; a
/// synonym of a listed code, such as `fra` next to `fre`, is labelled with
/// the code so the two are not both "French").
class LanguageTile extends StatelessWidget {
  const LanguageTile({
    super.key,
    required this.setting,
    required this.icon,
    required this.title,
    required this.value,
    required this.onSetting,
  });

  /// The `Settings` key this tile edits.
  final String setting;
  final IconData icon;
  final String title;
  final String? value;
  final SettingWriter onSetting;

  static const String defaultLabel = 'Player default';

  @override
  Widget build(BuildContext context) {
    final codes = [null, for (final option in languageOptions) option.code];
    return ChoiceTile<String?>(
      setting: setting,
      icon: icon,
      title: title,
      value: value,
      options: codes,
      label: (code) {
        if (code == null) return defaultLabel;
        final name = languageName(code);
        if (codes.contains(code) || name == code) return name;
        return '$name ($code)';
      },
      onSetting: onSetting,
    );
  }
}
