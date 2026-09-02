import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../widgets/content_type_label.dart';
import 'addon_widgets.dart';

/// One addon by manifest URL (`addon_details`): the fetched manifest next
/// to the installed copy, with Install / Update / Uninstall / Configure.
///
/// On mount it dispatches `Load AddonDetails {transportUrl}` (a `stremio://`
/// URL is accepted; the engine reads it as `https://`) and unloads the field
/// on dispose. The engine fills `localAddon` from the profile and
/// `remoteAddon` from the fetch, and refreshes both after every mutation, so
/// the buttons follow the state: Install while not installed, Update when
/// the fetched version differs, Uninstall unless protected. A manifest that
/// declares `configurationRequired` cannot be installed (`Other` code 6):
/// its primary action is Configure. While `profile.addonsLocked` every
/// mutation is disabled behind a banner.
class AddonDetailsScreen extends StatefulWidget {
  const AddonDetailsScreen({super.key, required this.transportUrl});

  /// The manifest URL, as typed or as a catalog entry carries it.
  final String transportUrl;

  @override
  State<AddonDetailsScreen> createState() => _AddonDetailsScreenState();
}

class _AddonDetailsScreenState extends State<AddonDetailsScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _details;
  CoreFieldNotifier? _ctx;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _details?.dispose();
      _ctx?.dispose();
      _client = client;
      _details = CoreFieldNotifier(client, CoreField.addonDetails);
      _ctx = CoreFieldNotifier(client, CoreField.ctx);
      _load();
    }
  }

  @override
  void dispose() {
    _client?.dispatch(CoreActions.unload(CoreField.addonDetails));
    _details?.dispose();
    _ctx?.dispose();
    super.dispose();
  }

  void _load() =>
      _client?.dispatch(CoreActions.loadAddonDetails(widget.transportUrl));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_details!, _ctx!]),
      builder: (context, _) {
        final json = _details!.value;
        final state = json == null ? null : AddonDetailsState.fromJson(json);
        final ctx = _ctx!.value;
        final profile = ctx == null ? null : ProfileState.fromCtx(ctx);
        final descriptor = state?.descriptor;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              descriptor?.manifest.name ?? 'Addon',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: AddonErrorSnackBars(
            child: state == null || !state.isLoaded
                ? const Center(child: CircularProgressIndicator())
                : descriptor == null
                ? (state.manifestError == null
                      ? const Center(child: CircularProgressIndicator())
                      : _ManifestError(
                          transportUrl: state.transportUrl!,
                          message: state.manifestError!.message,
                          onRetry: _load,
                        ))
                : _Details(
                    state: state,
                    descriptor: descriptor,
                    profile: profile,
                    onInstall: () => _client?.dispatch(
                      CoreActions.installAddon(state.remoteDescriptor!),
                    ),
                    onUpgrade: () => _client?.dispatch(
                      CoreActions.upgradeAddon(state.remoteDescriptor!),
                    ),
                    onUninstall: () => _client?.dispatch(
                      CoreActions.uninstallAddon(state.localAddon!),
                    ),
                    onConfigure: () =>
                        openAddonConfiguration(context, descriptor),
                  ),
          ),
        );
      },
    );
  }
}

/// The manifest card and the actions below it.
class _Details extends StatelessWidget {
  const _Details({
    required this.state,
    required this.descriptor,
    required this.profile,
    required this.onInstall,
    required this.onUpgrade,
    required this.onUninstall,
    required this.onConfigure,
  });

  final AddonDetailsState state;
  final AddonDescriptor descriptor;
  final ProfileState? profile;
  final VoidCallback onInstall;
  final VoidCallback onUpgrade;
  final VoidCallback onUninstall;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manifest = descriptor.manifest;
    final locked = profile?.addonsLocked ?? false;
    final remote = state.remoteDescriptor;
    final local = state.localAddon;
    final configurationRequired =
        remote?.manifest.behaviorHints.configurationRequired ?? false;
    final hasConfigure = descriptor.configureUrl != null;
    final fetchError = state.manifestError;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (locked)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: AddonsLockedBanner(),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AddonLogo(url: manifest.logo, size: 72),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(manifest.name, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 2),
                  Text(
                    'v${manifest.version}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (local != null) const _Tag('Installed'),
                      if (descriptor.isOfficial) const _Tag('Official'),
                      if (descriptor.isProtected) const _Tag('Protected'),
                      if (configurationRequired)
                        const _Tag('Configuration required'),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (fetchError != null) ...[
          const SizedBox(height: 16),
          _InlineError(
            'The manifest could not be fetched: ${fetchError.message}',
          ),
        ],
        if (state.hasUpgrade) ...[
          const SizedBox(height: 16),
          Text(
            'Installed v${local!.manifest.version}, '
            'v${remote!.manifest.version} available.',
            style: theme.textTheme.bodyMedium,
          ),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            if (configurationRequired)
              FilledButton.icon(
                onPressed: onConfigure,
                icon: const Icon(Icons.tune),
                label: const Text('Configure'),
              )
            else if (local == null)
              FilledButton.icon(
                onPressed: locked || remote == null ? null : onInstall,
                icon: const Icon(Icons.download_outlined),
                label: const Text('Install'),
              )
            else if (state.hasUpgrade)
              FilledButton.icon(
                onPressed: locked ? null : onUpgrade,
                icon: const Icon(Icons.upgrade),
                label: const Text('Update'),
              ),
            if (local != null && !local.isProtected)
              OutlinedButton.icon(
                onPressed: locked ? null : onUninstall,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Uninstall'),
              ),
            if (hasConfigure && !configurationRequired)
              TextButton.icon(
                onPressed: onConfigure,
                icon: const Icon(Icons.tune),
                label: const Text('Configure'),
              ),
          ],
        ),
        if (manifest.description case final description?
            when description.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(description, style: theme.textTheme.bodyMedium),
        ],
        if (manifest.types.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('Types', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          AddonTypeLabels(types: manifest.types),
        ],
        if (manifest.resourceNames.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Resources', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Text(
            [for (final r in manifest.resourceNames) capitalise(r)].join(', '),
            style: theme.textTheme.bodyMedium,
          ),
        ],
        const SizedBox(height: 16),
        Text('Manifest URL', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        SelectableText(
          state.transportUrl ?? descriptor.transportUrl,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (manifest.contactEmail case final email? when email.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Contact', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          SelectableText(email, style: theme.textTheme.bodyMedium),
        ],
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      ],
    );
  }
}

/// The manifest fetch failed and nothing is installed under that URL.
class _ManifestError extends StatelessWidget {
  const _ManifestError({
    required this.transportUrl,
    required this.message,
    required this.onRetry,
  });

  final String transportUrl;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              'The manifest could not be fetched',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              transportUrl,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
