import 'addon_descriptor.dart';

/// View over `ctx.profile` (`Profile`, camelCase: `auth`, `addons`,
/// `addonsLocked`, `settings`). The `ctx` field itself is
/// `{profile, notifications, events}`; the library, streams and server
/// URLs it also holds are not serialized.
///
/// The auth key inside `auth` is deliberately not surfaced: the UI never
/// needs it, and nothing here should end up in a log.
final class ProfileState {
  const ProfileState(this.json);

  /// The `profile` of a `ctx` state.
  factory ProfileState.fromCtx(Map<String, dynamic> ctx) =>
      ProfileState(ctx['profile'] as Map<String, dynamic>? ?? const {});

  final Map<String, dynamic> json;

  /// The signed-in user, or null when anonymous.
  UserInfo? get user {
    final auth = json['auth'] as Map<String, dynamic>?;
    final user = auth?['user'] as Map<String, dynamic>?;
    return user == null ? null : UserInfo(user);
  }

  bool get isLoggedIn => user != null;

  List<AddonDescriptor> get addons =>
      AddonDescriptor.listFromJson(json['addons']);

  /// Raised when the API addon collection could not be fetched after login:
  /// the official addons are in use as a stand-in and every install /
  /// uninstall / upgrade fails (`Other` code 7) until `PullAddonsFromAPI`
  /// succeeds.
  bool get addonsLocked => json['addonsLocked'] as bool? ?? false;

  ProfileSettings get settings =>
      ProfileSettings(json['settings'] as Map<String, dynamic>? ?? const {});

  bool isAddonInstalled(String transportUrl) =>
      addons.any((addon) => addon.transportUrl == transportUrl);

  AddonDescriptor? installedAddon(String transportUrl) =>
      addons.where((addon) => addon.transportUrl == transportUrl).firstOrNull;
}

/// View over `Auth.user` (`User`; camelCase except `_id`, `premium_expire`
/// and `gdpr_consent`).
final class UserInfo {
  const UserInfo(this.json);

  final Map<String, dynamic> json;

  String get id => json['_id'] as String;
  String get email => json['email'] as String? ?? '';
  String? get avatar => json['avatar'] as String?;
  String? get fbId => json['fbId'] as String?;
  String? get appleId => json['appleId'] as String?;
  DateTime? get lastModified => _date(json['lastModified']);
  DateTime? get dateRegistered => _date(json['dateRegistered']);

  /// When the premium subscription ends; null without one.
  DateTime? get premiumExpire => _date(json['premium_expire']);

  GdprConsent get gdprConsent => GdprConsent.fromJson(
    json['gdpr_consent'] as Map<String, dynamic>? ?? const {},
  );

  static DateTime? _date(Object? json) =>
      json is String ? DateTime.tryParse(json)?.toUtc() : null;
}

/// `GDPRConsent`: what a `Register` request carries and what the user
/// record echoes back.
final class GdprConsent {
  const GdprConsent({
    required this.tos,
    required this.privacy,
    required this.marketing,
    this.from,
  });

  final bool tos;
  final bool privacy;
  final bool marketing;

  /// Which client collected the consent (`xtremio`).
  final String? from;

  factory GdprConsent.fromJson(Map<String, dynamic> json) => GdprConsent(
    tos: json['tos'] as bool? ?? false,
    privacy: json['privacy'] as bool? ?? false,
    marketing: json['marketing'] as bool? ?? false,
    from: json['from'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'tos': tos,
    'privacy': privacy,
    'marketing': marketing,
    'from': from,
  };
}

/// View over `Profile.settings` (`Settings`, camelCase). Typed accessors for
/// what the app reads; [withValue] produces the full map `UpdateSettings`
/// needs (the engine has no per-field defaults, so the whole object goes
/// back with one key changed, and unknown future keys pass through).
final class ProfileSettings {
  const ProfileSettings(this.json);

  final Map<String, dynamic> json;

  static const String streamingServerUrlKey = 'streamingServerUrl';
  static const String bingeWatchingKey = 'bingeWatching';
  static const String nextVideoNotificationDurationKey =
      'nextVideoNotificationDuration';
  static const String seekTimeDurationKey = 'seekTimeDuration';
  static const String seekShortTimeDurationKey = 'seekShortTimeDuration';
  static const String pauseOnMinimizeKey = 'pauseOnMinimize';
  static const String hardwareDecodingKey = 'hardwareDecoding';
  static const String audioLanguageKey = 'audioLanguage';
  static const String subtitlesLanguageKey = 'subtitlesLanguage';
  static const String subtitlesSizeKey = 'subtitlesSize';
  static const String subtitlesTextColorKey = 'subtitlesTextColor';
  static const String subtitlesBackgroundColorKey = 'subtitlesBackgroundColor';
  static const String quitOnCloseKey = 'quitOnClose';
  static const String escExitFullscreenKey = 'escExitFullscreen';
  static const String hideSpoilersKey = 'hideSpoilers';
  static const String interfaceLanguageKey = 'interfaceLanguage';

  /// Whether the engine sent any settings at all (an empty map means the
  /// `ctx` state has not been pulled yet).
  bool get isEmpty => json.isEmpty;

  /// The streaming server the engine talks to; loopback means the embedded
  /// server (retargeted to its actual port at init).
  String? get streamingServerUrl => json[streamingServerUrlKey] as String?;

  bool get bingeWatching => json[bingeWatchingKey] as bool? ?? true;

  /// Milliseconds the up-next card counts down; 0 disables it.
  int get nextVideoNotificationDuration =>
      _int(nextVideoNotificationDurationKey) ?? 35000;

  /// Milliseconds an arrow-key seek moves.
  int get seekTimeDuration => _int(seekTimeDurationKey) ?? 10000;

  /// Milliseconds a Shift + arrow-key seek moves (the *short* seek).
  int get seekShortTimeDuration => _int(seekShortTimeDurationKey) ?? 3000;

  bool get pauseOnMinimize => json[pauseOnMinimizeKey] as bool? ?? false;
  bool get hardwareDecoding => json[hardwareDecodingKey] as bool? ?? true;

  /// ISO 639-2 code (`eng`), or null for the player's default.
  String? get audioLanguage => json[audioLanguageKey] as String?;
  String? get subtitlesLanguage => json[subtitlesLanguageKey] as String?;

  /// Percent of the base size (100).
  int get subtitlesSize => _int(subtitlesSizeKey) ?? 100;

  /// `#RRGGBBAA`.
  String get subtitlesTextColor =>
      json[subtitlesTextColorKey] as String? ?? '#FFFFFFFF';

  /// `#RRGGBBAA`; fully transparent (`#00000000`) means no box.
  String get subtitlesBackgroundColor =>
      json[subtitlesBackgroundColorKey] as String? ?? '#00000000';

  bool get quitOnClose => json[quitOnCloseKey] as bool? ?? true;
  bool get escExitFullscreen => json[escExitFullscreenKey] as bool? ?? true;
  bool get hideSpoilers => json[hideSpoilersKey] as bool? ?? false;
  String get interfaceLanguage =>
      json[interfaceLanguageKey] as String? ?? 'eng';

  int? _int(String key) => (json[key] as num?)?.toInt();

  /// A copy of the whole settings map with [key] set to [value]: the
  /// argument of `CoreActions.updateSettings`.
  Map<String, dynamic> withValue(String key, Object? value) => {
    ...json,
    key: value,
  };
}
