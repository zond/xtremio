import 'addon_descriptor.dart';
import 'loadable.dart';

/// `AddonDetails.remoteAddon`: a `DescriptorLoadable`, which has no
/// `rename_all`, so its URL key is `transport_url` (unlike the camelCase
/// `selected.transportUrl` next to it).
final class RemoteAddon {
  const RemoteAddon({required this.transportUrl, required this.content});

  final String transportUrl;

  /// The fetched manifest as a descriptor (flags filled in from the
  /// official list when the URL matches), or the fetch error (`EnvError`
  /// `{code, message}`).
  final Loadable<AddonDescriptor> content;

  factory RemoteAddon.fromJson(Map<String, dynamic> json) => RemoteAddon(
    transportUrl: json['transport_url'] as String,
    content: Loadable.fromJson(
      json['content'] as Map<String, dynamic>?,
      (content) => AddonDescriptor(content as Map<String, dynamic>),
    ),
  );
}

/// View over the `addon_details` field (`AddonDetails`, camelCase): one
/// addon by manifest URL, its installed copy and its fetched manifest.
final class AddonDetailsState {
  const AddonDetailsState({
    required this.transportUrl,
    required this.localAddon,
    required this.remoteAddon,
  });

  /// `selected.transportUrl` (a `stremio://` URL is normalized to `https`
  /// by the engine), or null when the model is unloaded.
  final String? transportUrl;

  /// The profile's descriptor for this URL, when installed.
  final AddonDescriptor? localAddon;

  /// The manifest fetch; null until a Load happened.
  final RemoteAddon? remoteAddon;

  factory AddonDetailsState.fromJson(Map<String, dynamic> json) {
    final selected = json['selected'] as Map<String, dynamic>?;
    final localAddon = json['localAddon'] as Map<String, dynamic>?;
    final remoteAddon = json['remoteAddon'] as Map<String, dynamic>?;
    return AddonDetailsState(
      transportUrl: selected?['transportUrl'] as String?,
      localAddon: localAddon == null ? null : AddonDescriptor(localAddon),
      remoteAddon: remoteAddon == null
          ? null
          : RemoteAddon.fromJson(remoteAddon),
    );
  }

  bool get isLoaded => transportUrl != null;

  bool get isInstalled => localAddon != null;

  bool get isLoadingManifest => remoteAddon?.content.isLoading ?? isLoaded;

  /// The fetched descriptor, when the manifest loaded.
  AddonDescriptor? get remoteDescriptor => remoteAddon?.content.contentOrNull;

  /// The manifest fetch failure, when there is one.
  LoadableError<AddonDescriptor>? get manifestError =>
      switch (remoteAddon?.content) {
        final LoadableError<AddonDescriptor> error => error,
        _ => null,
      };

  /// What to show as the addon: the fetched manifest, else the installed
  /// copy while the fetch is pending or failed.
  AddonDescriptor? get descriptor => remoteDescriptor ?? localAddon;

  /// Installed, and the fetched manifest differs in version: offer
  /// `UpgradeAddon` (the engine refuses identical descriptors).
  bool get hasUpgrade {
    final (local, remote) = (localAddon, remoteDescriptor);
    if (local == null || remote == null) return false;
    return local.manifest.version != remote.manifest.version;
  }
}
