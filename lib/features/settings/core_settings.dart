import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/device_profile.dart';
import '../../widgets/explained.dart';
import '../../widgets/readout.dart';
import '../player/language_names.dart';
import '../player/playback_engine.dart';
import '../player/subtitle_color_chips.dart';
import '../diagnostics/diagnostics_trace.dart';
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
/// The focus indicator is the theme floor's throughout (switch rows, plain
/// rows, the language dropdowns), for the reason [SettingsScreen] gives. The
/// one exception is drawn elsewhere and marked there: the subtitle colours are
/// chips.
///
/// And what is read rather than pressed is a [Readout], which on a
/// television is a stop wearing the ring alone: the subtitle preview.
/// Nothing the floor can mark, because it is not a control.
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

  /// The up-next countdown's label. A zero is not the setting turned off: with
  /// Binge watching on, the next episode still starts the moment this one ends,
  /// just without the card and its seconds. The label says that, because
  /// "Disabled" (stremio-web's word, under a title that calls this a popup
  /// duration) read as "nothing plays next" under a title that calls it a
  /// countdown. A viewer who wanted exactly that picked it and got the
  /// opposite. What does stop the next episode is the Binge watching switch
  /// above, and the subtitle points there.
  static String upNextLabel(int millis) =>
      millis == 0 ? 'None (play at once)' : secondsLabel(millis);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Explained(
          title: 'Binge watching',
          explanation: 'When an episode ends, the next one starts.',
          child: SwitchListTile(
            key: settingKey(ProfileSettings.bingeWatchingKey),
            secondary: const ExplainIcon(Icon(Icons.skip_next_outlined)),
            title: const Text('Binge watching'),
            value: settings.bingeWatching,
            onChanged: (value) =>
                onSetting(ProfileSettings.bingeWatchingKey, value),
          ),
        ),
        ChoiceTile<int>(
          setting: ProfileSettings.nextVideoNotificationDurationKey,
          icon: Icons.timer_outlined,
          title: 'Up-next countdown',
          explanation:
              'How long the card before the next episode counts down. '
              'Turn off Binge watching to stop the next episode.',
          value: settings.nextVideoNotificationDuration,
          options: nextVideoDurations,
          label: upNextLabel,
          onSetting: onSetting,
        ),
        ChoiceTile<int>(
          setting: ProfileSettings.seekTimeDurationKey,
          icon: Icons.forward_10,
          title: 'Seek step',
          explanation: 'How far the arrow keys and the seek buttons jump.',
          value: settings.seekTimeDuration,
          options: seekDurations,
          label: secondsLabel,
          onSetting: onSetting,
        ),
        ChoiceTile<int>(
          setting: ProfileSettings.seekShortTimeDurationKey,
          icon: Icons.forward_5,
          title: 'Short seek step',
          explanation: 'How far Shift and an arrow key jump.',
          value: settings.seekShortTimeDuration,
          options: seekDurations,
          label: secondsLabel,
          onSetting: onSetting,
        ),
        Explained(
          title: 'Pause when minimised',
          explanation: 'Playback pauses when you leave the app.',
          child: SwitchListTile(
            key: settingKey(ProfileSettings.pauseOnMinimizeKey),
            secondary: const ExplainIcon(Icon(Icons.pause_circle_outline)),
            title: const Text('Pause when minimised'),
            value: settings.pauseOnMinimize,
            onChanged: (value) =>
                onSetting(ProfileSettings.pauseOnMinimizeKey, value),
          ),
        ),
        Explained(
          title: 'Hardware decoding',
          explanation:
              "Lets the device's own video chip draw the picture, which "
              'uses less power. A change applies to the next video you open.',
          child: SwitchListTile(
            key: settingKey(ProfileSettings.hardwareDecodingKey),
            secondary: const ExplainIcon(Icon(Icons.memory)),
            title: const Text('Hardware decoding'),
            value: settings.hardwareDecoding,
            onChanged: (value) =>
                onSetting(ProfileSettings.hardwareDecodingKey, value),
          ),
        ),
        LanguageTile(
          setting: ProfileSettings.audioLanguageKey,
          icon: Icons.audiotrack_outlined,
          title: 'Preferred audio language',
          explanation:
              'The language a video plays its sound in, when it has more '
              'than one.',
          value: settings.audioLanguage,
          onSetting: onSetting,
        ),
        LanguageTile(
          setting: ProfileSettings.subtitlesLanguageKey,
          icon: Icons.subtitles_outlined,
          title: 'Preferred subtitles language',
          explanation:
              'The subtitles a video starts with, when there are some in '
              'this language.',
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
    final choice = prefs.bufferAhead;
    return SettingTile(
      icon: Icons.hourglass_bottom_outlined,
      title: 'Buffer ahead',
      // The cost of the choice in force, which is what the viewer is
      // weighing when they open it.
      explanation:
          'How far ahead of you Xtremio fetches the film. More plays '
          'smoother and uses more data and space. '
          '${choice.label}: ${choice.description}',
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
/// same reason "Buffer ahead" is: it is about this device's room and display,
/// not about the account. It is offered on a television only. That is where the
/// indicator is drawn at all, and where the viewer is three metres away from a
/// projector screen. Off a television, focus follows a pointer or Tab, and
/// Material's own highlight does the job.
///
/// **A switch, not a dropdown.** [FocusEmphasis] has exactly two values, so a
/// menu is a control too many: it costs a press to open, a walk to the value
/// and a press to choose, where a switch costs one press. On a television a
/// dropdown also risks trapping the D-pad (as one did in the streaming-server
/// settings). It is labelled for what turning it on does rather than for the
/// axis it sits on, and it is a [SwitchListTile] like "Binge watching" above
/// rather than a shape of its own.
///
/// **The enum is still what is stored and what the ring reads**, both
/// values and the same key, so a stored choice of Bold is unaffected and
/// nothing about the drawing changes.
class FocusEmphasisSection extends StatelessWidget {
  const FocusEmphasisSection({super.key, required this.prefs});

  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    if (!DeviceScope.isTv(context)) return const SizedBox.shrink();
    return Explained(
      title: 'Bold focus',
      // The description of the value being turned on: the explanation says
      // what the switch buys, not what the setting currently is.
      explanation: FocusEmphasis.bold.description,
      child: SwitchListTile(
        // The same key shape a `profile.settings` control gets, so a test
        // finds this one the same way.
        key: settingKey(AppPrefs.focusEmphasisKey),
        secondary: const ExplainIcon(Icon(Icons.highlight_alt_outlined)),
        title: const Text('Bold focus'),
        value: prefs.focusEmphasis == FocusEmphasis.bold,
        onChanged: (on) => prefs.setFocusEmphasis(
          on ? FocusEmphasis.bold : FocusEmphasis.standard,
        ),
      ),
    );
  }
}

/// Settings → Streaming server → "Share while idle": whether the embedded
/// server goes on uploading to other people when nothing is playing (see
/// [IdleSharing], which holds the rule and the strings).
///
/// The app's own preference and not a `profile.settings` field, for the reason
/// "Buffer ahead" and "Bold focus" are: it is about this device's connection
/// and what powers it, not about the account. The same account on a television
/// and on a phone wants opposite answers. A switch like those, labelled for
/// what turning it on does.
///
/// **It is offered on every device**, unlike "Bold focus", because the
/// choice exists everywhere and now so does the default: sharing is on
/// until somebody turns it off here.
///
/// It writes only the preference. What reaches the server is
/// [IdleSharingPolicy]'s to send, so that one object decides for the whole app
/// and this screen is one of the things that can change its mind. It is the
/// *embedded* server it governs, the one holding what this device fetched.
///
/// **And it says when a "Not now" is holding it off.** The status light's popup
/// can stop the sharing for the rest of the run without touching the
/// preference, so the switch can be on over a run in which nothing is shared.
/// The tile says so on a line of its own rather than leaving the switch to
/// describe something the app is not doing. The line is only ever under a
/// switch that is on, and the policy holds that from both ends: either press of
/// the switch lifts a pause, and none can be granted while the switch is off.
/// So what the line promises, sharing again at the next start, is what the
/// setting will still be asking for then.
///
/// **And it says so while the pause is granted, not the next time the tab is
/// opened.** The popup is drawn over whatever screen is showing, this one
/// included, so the press that pauses the sharing lands with the tile in view.
/// So the tile listens to the policy ([IdleSharingPolicy] notifies when the
/// pause goes on or off) rather than reading it once. Reading the scope is not
/// enough on its own: the scope holds the same policy object either side of a
/// "Not now", and so has nothing to say about it.
class IdleSharingSection extends StatelessWidget {
  const IdleSharingSection({super.key, required this.prefs});

  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    // The scope with a dependency, so a tile under a scope that is replaced
    // follows the policy it is replaced with; the policy itself for the
    // pause, which is what changes while this is on screen.
    final policy = SharingScope.of(context)?.policy;
    if (policy == null) return _tile(paused: false, background: false);
    return ListenableBuilder(
      listenable: policy,
      builder: (context, _) => _tile(
        paused: policy.pausedForRun,
        background: policy.pausesInBackground,
      ),
    );
  }

  /// [background] is whether the sharing stops while the app is in the
  /// background on this device ([IdleSharingPolicy.pausesInBackground]),
  /// which the tile says in [IdleSharing.backgroundNote]. It is the device
  /// and never the app's state: the tile reads the same with the app away
  /// as with it in front.
  ///
  /// The pause is state, so it is the one line left under the title. What the
  /// switch does, and the background note, are the explanation.
  Widget _tile({required bool paused, required bool background}) => Explained(
    title: IdleSharing.title,
    explanation: background
        ? '${IdleSharing.description} ${IdleSharing.backgroundNote}'
        : IdleSharing.description,
    child: SwitchListTile(
      // The same key shape a `profile.settings` control gets, so a test
      // finds this one the same way.
      key: settingKey(AppPrefs.shareWhileIdleKey),
      secondary: const ExplainIcon(Icon(Icons.upload_outlined)),
      title: const Text(IdleSharing.title),
      subtitle: paused ? const Text(IdleSharing.pausedNote) : null,
      value: prefs.shareWhileIdle,
      onChanged: (on) => prefs.setShareWhileIdle(on),
    ),
  );
}

/// Settings → Developer → "Verbose diagnostics": whether the Diagnostics
/// log carries the streaming server's retention trace and mpv's demuxer,
/// stream and cache lines (see [AppPrefs.verboseDiagnosticsKey]).
///
/// The app's own preference, like "Share while idle" above it: what it feeds is
/// the embedded server's `diagnosticsTrace` and the next player's log level,
/// not a `profile.settings` field. It sits with the Diagnostics tile it changes
/// the contents of, rather than with the server settings, because somebody who
/// turns it on is about to copy a report.
class VerboseDiagnosticsSection extends StatelessWidget {
  const VerboseDiagnosticsSection({super.key, required this.prefs});

  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) => Explained(
    title: DiagnosticsTraceSync.title,
    explanation: DiagnosticsTraceSync.description,
    child: SwitchListTile(
      // The same key shape a `profile.settings` control gets, so a test
      // finds this one the same way.
      key: settingKey(AppPrefs.verboseDiagnosticsKey),
      secondary: const ExplainIcon(Icon(Icons.manage_search_outlined)),
      title: const Text(DiagnosticsTraceSync.title),
      value: prefs.verboseDiagnostics,
      onChanged: (on) => prefs.setVerboseDiagnostics(on),
    ),
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
          explanation: 'How large subtitles are drawn.',
          value: settings.subtitlesSize,
          options: SubtitleStyle.sizes,
          label: sizeLabel,
          onSetting: onSetting,
        ),
        Explained(
          title: 'Text colour',
          explanation:
              'The colour of subtitle text. The preview below shows it.',
          child: ListTile(
            key: settingKey(ProfileSettings.subtitlesTextColorKey),
            leading: const ExplainIcon(Icon(Icons.format_color_text)),
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
        ),
        Explained(
          title: 'Background',
          explanation:
              'The box behind subtitle text, or none. The preview below '
              'shows it.',
          child: ListTile(
            key: settingKey(ProfileSettings.subtitlesBackgroundColorKey),
            leading: const ExplainIcon(Icon(Icons.format_color_fill)),
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
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          // The one thing on this section worth looking at, and the reason
          // the chips above it are here. It took no focus, so on a
          // television it sat under the fold while the colour was picked:
          // the chips are the last stop of the section and a stop is
          // revealed with its own bottom at the bottom of the screen.
          child: Readout(
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
          Explained(
            title: 'Quit when the window closes',
            explanation: 'Not used yet. Closing the window always quits.',
            child: SwitchListTile(
              key: settingKey(ProfileSettings.quitOnCloseKey),
              secondary: const ExplainIcon(Icon(Icons.close)),
              title: const Text('Quit when the window closes'),
              value: settings.quitOnClose,
              onChanged: (value) =>
                  onSetting(ProfileSettings.quitOnCloseKey, value),
            ),
          ),
        Explained(
          title: 'Esc leaves fullscreen',
          explanation: 'Esc takes a fullscreen video back to its window.',
          child: SwitchListTile(
            key: settingKey(ProfileSettings.escExitFullscreenKey),
            secondary: const ExplainIcon(Icon(Icons.fullscreen_exit)),
            title: const Text('Esc leaves fullscreen'),
            value: settings.escExitFullscreen,
            onChanged: (value) =>
                onSetting(ProfileSettings.escExitFullscreenKey, value),
          ),
        ),
        Explained(
          title: 'Hide spoilers',
          explanation:
              'Not used yet. Episode thumbnails and summaries still show.',
          child: SwitchListTile(
            key: settingKey(ProfileSettings.hideSpoilersKey),
            secondary: const ExplainIcon(Icon(Icons.visibility_off_outlined)),
            title: const Text('Hide spoilers'),
            value: settings.hideSpoilers,
            onChanged: (value) =>
                onSetting(ProfileSettings.hideSpoilersKey, value),
          ),
        ),
      ],
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
    required this.explanation,
    required this.value,
    required this.options,
    required this.label,
    required this.onSetting,
  });

  /// The `Settings` key this tile edits.
  final String setting;
  final IconData icon;
  final String title;
  final String explanation;
  final T value;
  final List<T> options;
  final String Function(T value) label;
  final SettingWriter onSetting;

  @override
  Widget build(BuildContext context) {
    return SettingTile(
      icon: icon,
      title: title,
      explanation: explanation,
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
/// title, and the menu itself on a line of its own below both. What the
/// setting means and costs is its [explanation] ([Explained]).
///
/// **The menu is not the tile's `trailing`,** which is where it started and
/// where it does not fit. A [DropdownButton] measures itself against its
/// *widest* item rather than the chosen one: "Download the whole file" among
/// the buffer choices, "Portuguese (Brazil)" among the languages. `ListTile`
/// lets `trailing` be as wide as it likes, squeezing the title and subtitle
/// into whatever is left, clamped at zero. At a larger system font a 360 dp
/// phone's "Buffer ahead" tile grew past 1000 dp for one row, with the title
/// clipped away entirely at some widths.
///
/// **A widget test sees the worse end of it**, because the test font draws
/// every glyph a square, so `trailing` claims the whole tile width and a
/// `hasSize` assertion throws below about 436 dp.
///
/// On a line of its own the menu has that line to itself at any width, so
/// nothing here depends on how long the longest label happens to be. That is
/// the property worth having, since one of those lists is the languages, and it
/// grows. [SettingMenu] fills the line rather than measuring the labels again,
/// and a width breakpoint would have wanted a threshold per list.
class SettingTile extends StatelessWidget {
  const SettingTile({
    super.key,
    required this.icon,
    required this.title,
    required this.explanation,
    required this.menu,
  });

  final IconData icon;
  final String title;
  final String explanation;

  /// The control, which carries the [settingKey] a test finds it by.
  final Widget menu;

  @override
  Widget build(BuildContext context) => Explained(
    title: title,
    explanation: explanation,
    child: ListTile(
      leading: ExplainIcon(Icon(icon)),
      title: Text(title),
      // Under the title, so the menu starts where the text does and the
      // tile grows to hold it; the colour chips sit in the subtitle for the
      // same reason.
      subtitle: menu,
    ),
  );
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
    required this.explanation,
    required this.value,
    required this.onSetting,
  });

  /// The `Settings` key this tile edits.
  final String setting;
  final IconData icon;
  final String title;
  final String explanation;
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
      explanation: explanation,
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
