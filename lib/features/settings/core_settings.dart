import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../shell/tv_text_entry.dart';
import '../../widgets/tv_text_field.dart';
import '../player/language_names.dart';
import '../player/playback_engine.dart';
import '../player/subtitle_color_chips.dart';
import '../sharing/idle_sharing.dart';
import '../sharing/sharing_activity.dart';

/// Settings → Player / Subtitles / Interface / Streaming server: the
/// controls over `profile.settings`.
///
/// Every control reports one `(key, value)` through a [SettingWriter]; the
/// screen turns that into `UpdateSettings` with the *whole* map and that key
/// changed (`ProfileSettings.withValue`), since stremio-core has no
/// per-field defaults. Settings are device-local: the API never sees them.
///
/// The focus indicator is the theme floor's throughout -- switch rows,
/// plain rows, the language dropdowns -- for the reason [SettingsScreen]
/// gives. The two exceptions are drawn elsewhere and marked there: the
/// folder field is a [TvTextField] and the subtitle colours are chips.
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

  /// `nextVideoNotificationDuration` choices, ms: no card, then 5…90 s
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

  static String secondsLabel(int millis) => '${millis ~/ 1000} s';

  /// The up-next countdown's label. A zero is not the setting turned off:
  /// with Binge watching on, the next episode still starts the moment this
  /// one ends -- it just does so without the card and its seconds. The
  /// label says that, because "Disabled" (stremio-web's word, under a title
  /// that calls this a popup duration) read as "nothing plays next" under
  /// a title that calls it a countdown, and a viewer who wanted exactly
  /// that picked it and got the opposite. What does stop the next episode
  /// is the Binge watching switch above, and the subtitle points there.
  static String upNextLabel(int millis) =>
      millis == 0 ? 'None (play at once)' : secondsLabel(millis);

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
          subtitle:
              'How long the up-next card counts down before the next '
              'episode starts; turn off Binge watching to stop it starting',
          value: settings.nextVideoNotificationDuration,
          options: nextVideoDurations,
          label: upNextLabel,
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

/// Settings → Player → "Buffer ahead": how far ahead playback reads, and
/// the option that stops buffering and keeps the file instead.
///
/// This one is *not* a `profile.settings` field. It is the app's own choice
/// (`AppPrefs.bufferAhead`, `rust/src/prefs.rs`), because it is about this
/// device's connection and disk rather than about the account, and because
/// stremio-core's `Settings` has no field for it. So it takes an [AppPrefs]
/// rather than a [SettingWriter], and it renders whether or not the `ctx`
/// field has arrived.
class BufferAheadSection extends StatelessWidget {
  const BufferAheadSection({super.key, required this.prefs});

  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    return SettingTile(
      icon: Icons.hourglass_bottom_outlined,
      title: 'Buffer ahead',
      subtitle: prefs.bufferAhead.description,
      menu: SettingMenu<BufferAhead>(
        // The same key shape a `profile.settings` control gets, so a test
        // finds this one the same way.
        setting: AppPrefs.bufferAheadKey,
        value: prefs.bufferAhead,
        options: BufferAhead.values,
        label: (choice) => choice.label,
        onPicked: prefs.setBufferAhead,
      ),
    );
  }
}

/// Settings → Interface → "Bold focus": how strongly the thing the remote
/// is on is marked (see [FocusEmphasis]).
///
/// The app's own preference rather than a `profile.settings` field, for the
/// same reason "Buffer ahead" is: it is about this device's room and
/// display, not about the account. It is offered on a television only —
/// that is where the indicator is drawn at all, and where the viewer is
/// three metres away from a projector screen; off one, focus follows a
/// pointer or Tab and Material's own highlight does the job.
///
/// **A switch, not a dropdown.** [FocusEmphasis] has exactly two values, so
/// a menu is a control too many: it costs a press to open, a walk to the
/// value and a press to choose where a switch costs one press, and on a
/// television a dropdown is the shape that once trapped the D-pad in the
/// streaming-server settings. It is labelled for what turning it on does
/// rather than for the axis it sits on, and it is a [SwitchListTile] like
/// "Binge watching" above rather than a shape of its own.
///
/// **The enum is still what is stored and what the ring reads**, both
/// values and the same key, so somebody who chose Bold before this keeps
/// it and nothing about the drawing changes.
class FocusEmphasisSection extends StatelessWidget {
  const FocusEmphasisSection({super.key, required this.prefs});

  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    if (!DeviceScope.isTv(context)) return const SizedBox.shrink();
    return SwitchListTile(
      // The same key shape a `profile.settings` control gets, so a test
      // finds this one the same way.
      key: settingKey(AppPrefs.focusEmphasisKey),
      secondary: const Icon(Icons.highlight_alt_outlined),
      title: const Text('Bold focus'),
      // What it does is on the tile rather than in a help page, and it is
      // the description of the value being turned on -- the subtitle says
      // what the switch buys, not what the setting currently is.
      subtitle: Text(FocusEmphasis.bold.description),
      value: prefs.focusEmphasis == FocusEmphasis.bold,
      onChanged: (on) => prefs.setFocusEmphasis(
        on ? FocusEmphasis.bold : FocusEmphasis.standard,
      ),
    );
  }
}

/// Settings → Streaming server → "Share while idle": whether the embedded
/// server goes on uploading to other people when nothing is playing (see
/// [IdleSharing], which holds the rule and the strings).
///
/// The app's own preference and not a `profile.settings` field, for the
/// reason "Buffer ahead" and "Bold focus" are: it is about this device's
/// connection and what powers it, not about the account -- and the same
/// account on a television and on a phone wants opposite answers. A switch
/// like those, labelled for what turning it on does.
///
/// **It is offered on every device**, unlike "Bold focus", because the
/// choice exists everywhere and now so does the default: sharing is on
/// until somebody turns it off here.
///
/// It writes only the preference; what reaches the server is
/// [IdleSharingPolicy]'s to send, so that one object decides for the whole
/// app and this screen is one of the things that can change its mind. It is
/// the *embedded* server either way -- with a remote server chosen, this
/// still governs the one on this device, which is the one holding what this
/// device fetched.
///
/// **And it says when a "Not now" is holding it off.** The status light's
/// popup can stop the sharing for the rest of the run without touching the
/// preference, so the switch can be on over a run in which nothing is
/// shared; the tile says so on a line of its own rather than leaving the
/// switch to describe something the app is not doing. The line is only
/// ever under a switch that is on, and the policy holds that from both
/// ends: either press of the switch lifts a pause, and none can be granted
/// while the switch is off. So what the line promises -- sharing again at
/// the next start -- is what the setting will still be asking for then.
///
/// **And it says so while the pause is granted, not the next time the tab
/// is opened.** The popup is drawn over whatever screen is showing, this
/// one included, so the press that pauses the sharing lands with the tile
/// in view: it listens to the policy ([IdleSharingPolicy] notifies when
/// the pause goes on or off) rather than reading it once. Reading the
/// scope is not enough on its own -- the scope holds the same policy
/// object either side of a "Not now" and so has nothing to say about it.
class IdleSharingSection extends StatelessWidget {
  const IdleSharingSection({super.key, required this.prefs});

  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    // The scope with a dependency, so a tile under a scope that is replaced
    // follows the policy it is replaced with; the policy itself for the
    // pause, which is what changes while this is on screen.
    final policy = SharingScope.of(context)?.policy;
    if (policy == null) return _tile(paused: false);
    return ListenableBuilder(
      listenable: policy,
      builder: (context, _) => _tile(paused: policy.pausedForRun),
    );
  }

  Widget _tile({required bool paused}) => SwitchListTile(
    // The same key shape a `profile.settings` control gets, so a test
    // finds this one the same way.
    key: settingKey(AppPrefs.shareWhileIdleKey),
    secondary: const Icon(Icons.upload_outlined),
    title: const Text(IdleSharing.title),
    subtitle: Text(
      paused
          ? '${IdleSharing.description}\n${IdleSharing.pausedNote}'
          : IdleSharing.description,
    ),
    value: prefs.shareWhileIdle,
    onChanged: (on) => prefs.setShareWhileIdle(on),
  );
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

  /// Whether [a] and [b] are one server URL as stremio-core keeps it: the
  /// same up to the trailing slash its `Url` serialisation adds. What is
  /// sent is what was typed, and what a pull shows back is the engine's
  /// `Url`, so the two strings differ for every URL typed without a path.
  static bool sameUrl(String a, String b) {
    final left = Uri.tryParse(a);
    final right = Uri.tryParse(b);
    return left != null &&
        right != null &&
        _normalize(left) == _normalize(right);
  }

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

  /// One of the two server choices: which server the engine streams from.
  ///
  /// A radio in the group off a television. On one it is a plain tile with
  /// the radio's own icon instead, because [RadioGroup] claims all four
  /// arrow keys while one of its radios has focus -- they move the
  /// *selection*, wrapping around at the ends -- so a D-pad that walked
  /// onto the pair could never leave it again, and rewrote the setting on
  /// every press trying. As a tile the choice is a stop the D-pad walks
  /// through and select presses, like every other tile on the screen.
  Widget _choice({
    required bool isTv,
    required Key key,
    required bool value,
    required bool selected,
    required bool enabled,
    required String title,
    Widget? subtitle,
  }) {
    if (!isTv) {
      return RadioListTile<bool>(
        key: key,
        value: value,
        enabled: enabled,
        title: Text(title),
        subtitle: subtitle,
      );
    }
    return ListTile(
      key: key,
      enabled: enabled,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
      ),
      title: Text(title),
      subtitle: subtitle,
      onTap: () => _pick(value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final embedded = widget.embeddedUrl;
    final remote = _remote;
    final error = _error;
    final isTv = DeviceScope.isTv(context);
    final choices = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _choice(
          isTv: isTv,
          key: StreamingServerSection.embeddedKey,
          value: false,
          selected: !remote,
          enabled: embedded != null,
          title: 'Embedded server',
          subtitle: Text(embedded?.toString() ?? 'Not running'),
        ),
        _choice(
          isTv: isTv,
          key: StreamingServerSection.remoteKey,
          value: true,
          selected: remote,
          enabled: true,
          title: 'Remote server',
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
                      child: TvTextField(
                        key: StreamingServerSection.remoteUrlFieldKey,
                        controller: _url,
                        kind: TvTextKind.url,
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
    );
    // A television gets no [RadioGroup]: nothing under it is a radio, and
    // the group exists to give the radios their keyboard behaviour.
    return isTv
        ? choices
        : RadioGroup<bool>(
            groupValue: remote,
            onChanged: _pick,
            child: choices,
          );
  }
}

/// A setting with a fixed list of values, as a [SettingTile] whose menu
/// writes through a [SettingWriter] -- the shape every `profile.settings`
/// choice on this screen takes.
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
    return SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      menu: SettingMenu<T>(
        setting: setting,
        value: value,
        options: options,
        label: label,
        onPicked: (selected) => onSetting(setting, selected),
      ),
    );
  }
}

/// A settings tile whose value is picked from a menu: the icon and the
/// title, what the setting costs under them, and the menu itself on a line
/// of its own below both.
///
/// **The menu is not the tile's `trailing`,** which is where it started and
/// where it does not fit. A [DropdownButton] measures itself against its
/// *widest* item rather than the chosen one -- "Download the whole file"
/// among the buffer choices, "Portuguese (Brazil)" among the languages --
/// and `ListTile` lets `trailing` be as wide as it likes in the whole
/// content width, then lays the title and the subtitle out in what is left
/// of that, clamped at zero. So the menu had the row and the words had
/// what was left: the "Buffer ahead" tile was 184 dp tall on a 360 dp
/// phone with its title clipped to 67 dp, and 376 dp tall at 320 dp with
/// 27 dp of it. Turn the system font up a third and a 360 dp phone gets a
/// 1002 dp tile -- a screenful and a half for one row -- and 320 dp gets
/// no title at all. Nothing was wrong at the 900 dp every other test of
/// this screen mounts it at, which is the only width it had ever been laid
/// out at.
///
/// **A widget test sees the worse end of it**, because the test font draws
/// every glyph a square: that makes the menu 395 dp wide against the
/// 320 dp of content a 360 dp phone has, and a `trailing` measuring
/// exactly the tile width is the assertion "Trailing widget consumes the
/// entire tile width", which takes the screen down with a cascade of
/// `hasSize` failures behind it. It fires below about 436 dp; above that
/// nothing throws and the tile is 920 dp tall until about 700 dp, so the
/// width at which the screen stops throwing is nowhere near the width at
/// which it is right.
///
/// On a line of its own the menu has that line to itself at any width, so
/// nothing here depends on how long the longest label happens to be --
/// which is the property worth having, since one of those lists is the
/// languages and it grows. [SettingMenu] fills the line rather than
/// measuring the labels again, and a width breakpoint would have wanted a
/// threshold per list.
class SettingTile extends StatelessWidget {
  const SettingTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.menu,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// The control, which carries the [settingKey] a test finds it by.
  final Widget menu;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      // Both under the title, so the menu starts where the text does and
      // the tile grows to hold them; the colour chips below sit in the
      // subtitle for the same reason.
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [if (subtitle != null) Text(subtitle), menu],
      ),
    );
  }
}

/// The menu on a [SettingTile]: the current value, the [options] to pick from,
/// and the pick reported once.
///
/// A value outside [options] is listed too, so the menu never claims a
/// value the profile does not hold, and picking the value already in force
/// reports nothing.
///
/// `isExpanded` is what keeps it inside the row it is given: without it a
/// [DropdownButton] is as wide as its widest item and overflows anything
/// narrower, which is the whole of the trouble [SettingTile] describes.
class SettingMenu<T> extends StatelessWidget {
  const SettingMenu({
    super.key,
    required this.setting,
    required this.value,
    required this.options,
    required this.label,
    required this.onPicked,
  });

  /// The `Settings` (or [AppPrefs]) key this picks, which is also the
  /// widget key it is found by ([settingKey]).
  final String setting;
  final T value;
  final List<T> options;
  final String Function(T value) label;
  final ValueChanged<T> onPicked;

  @override
  Widget build(BuildContext context) {
    final items = options.contains(value) ? options : [...options, value];
    return DropdownButton<T>(
      key: settingKey(setting),
      value: value,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      items: [
        for (final option in items)
          DropdownMenuItem<T>(value: option, child: Text(label(option))),
      ],
      // `selected is T` rather than a cast: `T` is nullable in the language
      // tiles, where the default is a null value like any other, and not in
      // the rest.
      onChanged: (selected) {
        if (selected is T && selected != value) onPicked(selected);
      },
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
