import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/tv_density.dart';
import '../../shell/tv_text_entry.dart';
import '../../widgets/content_type_label.dart';
import '../../widgets/filter_controls.dart';
import '../../widgets/shared_field_screen.dart';
import '../../widgets/tv_text_field.dart';
import 'addon_details_screen.dart';
import 'addon_health.dart';
import 'addon_health_client.dart';
import 'addon_health_view.dart';
import 'addon_tile.dart';
import 'addon_widgets.dart';

/// Addons: the profile's (`installed_addons`) and the community catalog
/// (`remote_addons`), plus "Add addon" by manifest URL.
///
/// On mount it dispatches `Load InstalledAddonsWithFilters {type: null}` and
/// `Load CatalogWithFilters` with no request (the engine picks the first
/// addon catalog, Cinemeta's); both fields are unloaded on dispose, unless
/// another Addons screen has loaded them since. Every
/// filter option carries the request that selects it and the controls
/// dispatch those verbatim. The Installed list follows the profile on its
/// own after each mutation; whether a community entry is installed is not
/// part of the model, so it is read off `ctx.profile.addons`. Search over
/// the community list is client-side (name and description), as in
/// stremio-web. While `profile.addonsLocked` every mutation is disabled
/// behind a banner.
///
/// Installed also carries each addon's health: what it has answered, read
/// once on mount from the [AddonHealthScope] above (nothing is shown
/// without one), turned into a verdict by `AddonHealth.verdict`. Health
/// adds no way to remove an addon -- Uninstall is the same menu item it
/// always was, still absent for a protected addon and still disabled while
/// the profile is locked -- because a verdict is advice and the decision
/// stays the viewer's.
class AddonsScreen extends StatefulWidget {
  const AddonsScreen({super.key});

  /// From this width on, types are a segmented button rather than chips.
  static const double wideBreakpoint = 720;

  /// Label of the `type: null` (installed) and `type: "all"` (community)
  /// entries.
  static const String allTypesLabel = 'All';

  /// Display name of a type option: [allTypesLabel] for the "everything"
  /// entry, else the plural the rest of the app uses.
  static String typeLabel(String? type) => switch (type) {
    null || 'all' => allTypesLabel,
    final type => contentTypeLabel(type),
  };

  @override
  State<AddonsScreen> createState() => _AddonsScreenState();
}

class _AddonsScreenState extends State<AddonsScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _installed;
  CoreFieldNotifier? _remote;
  CoreFieldNotifier? _ctx;
  final TextEditingController _search = TextEditingController();
  int _nextPageRequestedAt = -1;
  AddonHealthNotifier? _health;
  AddonHealthSort _sort = AddonHealthSort.profileOrder;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _installed?.dispose();
      _remote?.dispose();
      _ctx?.dispose();
      _client = client;
      _installed = CoreFieldNotifier(client, CoreField.installedAddons);
      _remote = CoreFieldNotifier(client, CoreField.remoteAddons);
      _ctx = CoreFieldNotifier(client, CoreField.ctx);
      _nextPageRequestedAt = -1;
      SharedFieldOwnership.claim(CoreField.installedAddons, this);
      SharedFieldOwnership.claim(CoreField.remoteAddons, this);
      client.dispatch(
        CoreActions.loadInstalledAddons(const InstalledAddonsRequest()),
      );
      client.dispatch(CoreActions.loadRemoteAddons(null));
    }
    // Built even with no client above -- an empty report is what "nothing
    // can tell us how these have been answering" looks like, and the tab
    // then shows no verdicts rather than empty ones.
    final health = AddonHealthScope.maybeOf(context);
    final current = _health;
    if (current == null || current.client != health) {
      current?.dispose();
      _health = AddonHealthNotifier(health)..load();
    }
  }

  @override
  void dispose() {
    // A popping route stays in the tree for its transition while the screen
    // beneath is already tappable, so a new Addons screen can have loaded
    // the lists by now: only their owner unloads them.
    SharedFieldOwnership.release(CoreField.installedAddons, this, _client);
    SharedFieldOwnership.release(CoreField.remoteAddons, this, _client);
    _installed?.dispose();
    _remote?.dispose();
    _ctx?.dispose();
    _health?.dispose();
    _search.dispose();
    super.dispose();
  }

  void _selectRemote(ResourceRequest request) {
    _nextPageRequestedAt = -1;
    _client?.dispatch(CoreActions.loadRemoteAddons(request));
  }

  bool _onRemoteScroll(ScrollNotification notification, RemoteAddonsState s) {
    if (notification.metrics.extentAfter < 600 &&
        s.nextPage != null &&
        !s.isLoading &&
        _nextPageRequestedAt != s.addons.length) {
      _nextPageRequestedAt = s.addons.length;
      _client?.dispatch(CoreActions.loadRemoteAddonsNextPage());
    }
    return false;
  }

  void _openDetails(String transportUrl) {
    Navigator.of(context).push(AddonDetailsScreen.route(transportUrl));
  }

  /// Pulls the account's addons again, so one installed on the website (or
  /// in another Stremio client) shows up here.
  void _refreshFromAccount() {
    _client?.dispatch(CoreActions.pullAddonsFromAPI());
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text(AddonDirectoryBar.refreshingMessage)),
    );
  }

  Future<void> _addByUrl() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const AddAddonDialog(),
    );
    if (url != null && mounted) _openDetails(url);
  }

  /// Drops everything recorded about one addon, for when the verdict is
  /// wrong -- most often right after a debrid key was replaced, where the
  /// old key's failures are about a configuration that no longer exists.
  /// It removes history and nothing else: the addon stays installed.
  Future<void> _forgetHistory(AddonDescriptor addon) async {
    final health = _health;
    final forgotten =
        health != null &&
        await health.forget(addonHealthKey(addon.transportUrl));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(_forgottenMessage(addon, forgotten))),
    );
  }

  /// What the viewer is told afterwards. Only a record that is really gone
  /// gets the past tense: the call can throw (a core on its way out) or
  /// find nothing under the key, and either way the verdict is still on the
  /// tile behind the snackbar.
  static String _forgottenMessage(AddonDescriptor addon, bool forgotten) =>
      forgotten
      ? 'Forgot how ${addon.manifest.name} has been answering'
      : 'Could not forget how ${addon.manifest.name} has been answering';

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: TvSafeArea(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Addons'),
            actions: [
              IconButton(
                tooltip: 'Add addon',
                icon: const Icon(Icons.add_link),
                onPressed: _addByUrl,
              ),
            ],
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Installed'),
                Tab(text: 'Community'),
              ],
            ),
          ),
          body: AddonErrorSnackBars(
            child: ListenableBuilder(
              listenable: Listenable.merge([
                _installed!,
                _remote!,
                _ctx!,
                _health!,
              ]),
              builder: (context, _) {
                final ctx = _ctx!.value;
                final profile = ctx == null
                    ? const ProfileState({})
                    : ProfileState.fromCtx(ctx);
                final installedJson = _installed!.value;
                final remoteJson = _remote!.value;
                return Column(
                  children: [
                    if (profile.addonsLocked) const AddonsLockedBanner(),
                    AddonDirectoryBar(onRefresh: _refreshFromAccount),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _InstalledTab(
                            state: installedJson == null
                                ? null
                                : InstalledAddonsState.fromJson(installedJson),
                            locked: profile.addonsLocked,
                            health: _health!,
                            sort: _sort,
                            onSort: (sort) => setState(() => _sort = sort),
                            onForget: _forgetHistory,
                            onSelect: (request) => _client?.dispatch(
                              CoreActions.loadInstalledAddons(request),
                            ),
                            onUninstall: (addon) => _client?.dispatch(
                              CoreActions.uninstallAddon(addon),
                            ),
                            onConfigure: (addon) =>
                                openAddonConfiguration(context, addon),
                            onOpen: (addon) => _openDetails(addon.transportUrl),
                          ),
                          _CommunityTab(
                            state: remoteJson == null
                                ? null
                                : RemoteAddonsState.fromJson(remoteJson),
                            profile: profile,
                            search: _search,
                            onSelect: _selectRemote,
                            onScroll: _onRemoteScroll,
                            onInstall: (addon) => _client?.dispatch(
                              CoreActions.installAddon(addon),
                            ),
                            onConfigure: (addon) =>
                                openAddonConfiguration(context, addon),
                            onOpen: (addon) => _openDetails(addon.transportUrl),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Where to find addons this catalog does not list, and how one installed
/// there arrives here.
///
/// stremio-addons.net is the community's directory; its Install button
/// hands the platform a `stremio://` link, which this app registers and
/// opens as an addon details screen. It is a link out to the browser
/// through the [ExternalLinkScope] and never an in-app web view.
///
/// [onRefresh] is the other half, and the only half a television has: a
/// remote cannot work a browser, so a TV user installs on a phone or a
/// laptop *into their Stremio account* and pulls it down here. That is what
/// the line under the buttons says.
///
/// It sits above the tabs so both of them have it, and it is two ordinary
/// buttons so the D-pad reaches them like anything else.
class AddonDirectoryBar extends StatelessWidget {
  const AddonDirectoryBar({super.key, required this.onRefresh});

  /// Pulls the account's addon list again (`PullAddonsFromAPI`).
  final VoidCallback onRefresh;

  static const String directoryUrl = 'https://stremio-addons.net';
  static const String directoryLabel = 'Find more addons at stremio-addons.net';
  static const String refreshLabel = 'Refresh addons from account';
  static const String refreshingMessage = 'Refreshing addons from your account';
  static const String explanation =
      'Installing one there into your Stremio account brings it here after '
      'a refresh.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            children: [
              TextButton.icon(
                onPressed: () => openInBrowser(context, directoryUrl),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text(directoryLabel),
              ),
              TextButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.sync, size: 18),
                label: const Text(refreshLabel),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              explanation,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Type filter shared by both tabs: segments on wide layouts, chips on
/// narrow ones.
class _TypeFilter<R> extends StatelessWidget {
  const _TypeFilter({required this.options, required this.onSelect});

  final List<FilterOption<R>> options;
  final ValueChanged<R> onSelect;

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.sizeOf(context).width >= AddonsScreen.wideBreakpoint;
    return isWide
        ? FilterSegments(options: options, onSelect: onSelect)
        : FilterChips(options: options, onSelect: onSelect);
  }
}

enum _InstalledAction { configure, uninstall, forget, details }

/// The profile's addons filtered by type, each with what it has been
/// answering.
class _InstalledTab extends StatelessWidget {
  const _InstalledTab({
    required this.state,
    required this.locked,
    required this.health,
    required this.sort,
    required this.onSort,
    required this.onForget,
    required this.onSelect,
    required this.onUninstall,
    required this.onConfigure,
    required this.onOpen,
  });

  final InstalledAddonsState? state;
  final bool locked;
  final AddonHealthNotifier health;
  final AddonHealthSort sort;
  final ValueChanged<AddonHealthSort> onSort;
  final ValueChanged<AddonDescriptor> onForget;
  final ValueChanged<InstalledAddonsRequest> onSelect;
  final ValueChanged<AddonDescriptor> onUninstall;
  final ValueChanged<AddonDescriptor> onConfigure;
  final ValueChanged<AddonDescriptor> onOpen;

  static const String sortLabel = 'Sort';
  static const String forgetLabel = 'Forget this addon\'s history';

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    if (state == null || !state.isLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final types = [
      for (final type in state.types)
        FilterOption(
          label: AddonsScreen.typeLabel(type.type),
          selected: type.selected,
          request: type.request,
        ),
    ];
    // Null until a report has actually been read: an addon nothing can be
    // read about is shown with nothing said about it, never with "not used
    // yet", which is a claim about the addon and not about the record.
    final report = health.report;
    final now = DateTime.now().toUtc();
    final addons = report == null
        ? state.addons
        : sortedByHealth(state.addons, sort, report, now);
    return Column(
      children: [
        if (report != null && report.everyAnswerFailed)
          const AddonConnectionBanner(),
        if (types.isNotEmpty || report != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (types.isNotEmpty)
                  _TypeFilter(options: types, onSelect: onSelect),
                // Only offered when something can tell the addons apart:
                // with no health record every order but the profile's is a
                // guess.
                if (report != null)
                  FilterMenu<AddonHealthSort>(
                    label: sortLabel,
                    options: [
                      for (final option in AddonHealthSort.values)
                        FilterOption(
                          label: option.label,
                          selected: option == sort,
                          request: option,
                        ),
                    ],
                    onSelect: onSort,
                  ),
              ],
            ),
          ),
        Expanded(
          child: addons.isEmpty
              ? const _Empty('No installed addons for this type')
              : ListView.separated(
                  itemCount: addons.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final addon = addons[index];
                    // Null for a protected addon, and for an addon nothing
                    // can be read about: neither gets a label.
                    final addonHealth = report?.healthOf(addon);
                    return AddonTile(
                      addon: addon,
                      onTap: () => onOpen(addon),
                      memoryId: 'installed/${addon.transportUrl}',
                      defaultFocus: index == 0,
                      status: addonHealth == null
                          ? null
                          : AddonHealthChip(
                              addon: addon,
                              health: addonHealth,
                              now: now,
                            ),
                      trailing: PopupMenuButton<_InstalledAction>(
                        tooltip: 'More',
                        onSelected: (action) => switch (action) {
                          _InstalledAction.configure => onConfigure(addon),
                          _InstalledAction.uninstall => onUninstall(addon),
                          _InstalledAction.forget => onForget(addon),
                          _InstalledAction.details => onOpen(addon),
                        },
                        itemBuilder: (_) => [
                          if (addon.manifest.behaviorHints.configurable)
                            const PopupMenuItem(
                              value: _InstalledAction.configure,
                              child: Text('Configure'),
                            ),
                          if (!addon.isProtected)
                            PopupMenuItem(
                              value: _InstalledAction.uninstall,
                              enabled: !locked,
                              child: const Text('Uninstall'),
                            ),
                          if (addonHealth != null && !addonHealth.isEmpty)
                            const PopupMenuItem(
                              value: _InstalledAction.forget,
                              child: Text(forgetLabel),
                            ),
                          const PopupMenuItem(
                            value: _InstalledAction.details,
                            child: Text('Details'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// One addon catalog with its filters and a client-side search.
class _CommunityTab extends StatelessWidget {
  const _CommunityTab({
    required this.state,
    required this.profile,
    required this.search,
    required this.onSelect,
    required this.onScroll,
    required this.onInstall,
    required this.onConfigure,
    required this.onOpen,
  });

  final RemoteAddonsState? state;
  final ProfileState profile;
  final TextEditingController search;
  final ValueChanged<ResourceRequest> onSelect;
  final bool Function(ScrollNotification, RemoteAddonsState) onScroll;
  final ValueChanged<AddonDescriptor> onInstall;
  final ValueChanged<AddonDescriptor> onConfigure;
  final ValueChanged<AddonDescriptor> onOpen;

  /// [addons] whose name or description contains [query]
  /// (case-insensitive); everything for a blank query.
  static List<AddonDescriptor> filter(
    List<AddonDescriptor> addons,
    String query,
  ) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return addons;
    return [
      for (final addon in addons)
        if (addon.manifest.name.toLowerCase().contains(needle) ||
            (addon.manifest.description?.toLowerCase().contains(needle) ??
                false))
          addon,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    if (state == null || !state.isLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final selectable = state.selectable;
    final catalogs = [
      for (final catalog in selectable.catalogs)
        FilterOption(
          label: catalog.label,
          selected: catalog.selected,
          request: catalog.request,
        ),
    ];
    final types = [
      for (final type in selectable.types)
        FilterOption(
          label: AddonsScreen.typeLabel(type.label),
          selected: type.selected,
          request: type.request,
        ),
    ];
    final addons = filter(state.addons, search.text);
    final error = state.lastError;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (catalogs.isNotEmpty)
                FilterMenu(
                  label: 'Catalog',
                  options: catalogs,
                  onSelect: onSelect,
                ),
              if (types.isNotEmpty)
                _TypeFilter(options: types, onSelect: onSelect),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: TvTextField(
            controller: search,
            onClear: search.clear,
            decoration: const InputDecoration(
              hintText: 'Search addons',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: state.addons.isEmpty
              ? (error != null && !error.isEmptyContent
                    ? _Failed(
                        message: error.message,
                        onRetry: () => onSelect(state.selected!),
                      )
                    : state.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : const _Empty('No addons in this catalog'))
              : addons.isEmpty
              ? const _Empty('No addons match')
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) => onScroll(n, state),
                  child: ListView.separated(
                    itemCount: addons.length + (state.isLoading ? 1 : 0),
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      if (index == addons.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final addon = addons[index];
                      return AddonTile(
                        addon: addon,
                        onTap: () => onOpen(addon),
                        memoryId: 'community/${addon.transportUrl}',
                        defaultFocus: index == 0,
                        trailing: _CommunityAction(
                          addon: addon,
                          installed: profile.isAddonInstalled(
                            addon.transportUrl,
                          ),
                          locked: profile.addonsLocked,
                          onInstall: () => onInstall(addon),
                          onConfigure: () => onConfigure(addon),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

/// Install, a disabled "Installed", or Configure for a manifest that must
/// be configured before it can be installed.
class _CommunityAction extends StatelessWidget {
  const _CommunityAction({
    required this.addon,
    required this.installed,
    required this.locked,
    required this.onInstall,
    required this.onConfigure,
  });

  final AddonDescriptor addon;
  final bool installed;
  final bool locked;
  final VoidCallback onInstall;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    if (installed) {
      return const FilledButton.tonal(
        onPressed: null,
        child: Text('Installed'),
      );
    }
    if (addon.manifest.behaviorHints.configurationRequired) {
      return FilledButton.tonal(
        onPressed: onConfigure,
        child: const Text('Configure'),
      );
    }
    return FilledButton(
      onPressed: locked ? null : onInstall,
      child: const Text('Install'),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scrollable: with the directory bar above it this panel does not fit a
    // 600 px-tall window, and a clipped Retry button is worse than a scroll.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              'The addon catalog could not be fetched',
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
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// Asks for a manifest URL; pops with it once it parses as an `http(s)` or
/// `stremio` URL with a host (the engine reads `stremio://` as `https://`).
class AddAddonDialog extends StatefulWidget {
  const AddAddonDialog({super.key});

  static const String invalidMessage =
      'Enter the addon\'s manifest URL (https://…/manifest.json)';

  /// The URL to open for [input], or null when it is not a manifest URL.
  static String? parse(String input) {
    final text = input.trim();
    final url = Uri.tryParse(text);
    if (url == null || !url.hasAuthority || url.host.isEmpty) return null;
    if (!const {'http', 'https', 'stremio'}.contains(url.scheme)) return null;
    return text;
  }

  @override
  State<AddAddonDialog> createState() => _AddAddonDialogState();
}

class _AddAddonDialogState extends State<AddAddonDialog> {
  final TextEditingController _url = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    final url = AddAddonDialog.parse(_url.text);
    if (url == null) {
      setState(() => _error = AddAddonDialog.invalidMessage);
      return;
    }
    Navigator.of(context).pop(url);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add addon'),
    content: TvTextField(
      controller: _url,
      autofocus: true,
      kind: TvTextKind.url,
      decoration: InputDecoration(
        labelText: 'Manifest URL',
        hintText: 'https://…/manifest.json',
        errorText: _error,
        errorMaxLines: 2,
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Open')),
    ],
  );
}
