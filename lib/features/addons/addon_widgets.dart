/// Pieces the addon screens share: the logo, the type labels, the
/// "addons locked" banner, the SnackBar for failed addon mutations and the
/// Configure link.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../shell/external_link.dart';
import '../../widgets/content_type_label.dart';

/// The manifest's logo, or an extension icon when there is none or it does
/// not load.
class AddonLogo extends StatelessWidget {
  const AddonLogo({super.key, required this.url, this.size = 48});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = Center(
      child: Icon(
        Icons.extension_outlined,
        size: size * 0.55,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 6),
      child: Container(
        width: size,
        height: size,
        color: theme.colorScheme.surfaceContainerHighest,
        child: url == null
            ? fallback
            : Image.network(
                url!,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

/// The meta types an addon serves, as small labels.
class AddonTypeLabels extends StatelessWidget {
  const AddonTypeLabels({super.key, required this.types});

  final List<String> types;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final type in types)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              contentTypeLabel(type),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// Shown while `profile.addonsLocked`: the account's addon collection could
/// not be fetched after login, the official addons stand in, and every
/// install / uninstall / upgrade fails (`Other` code 7) until the next
/// successful `PullAddonsFromAPI`.
class AddonsLockedBanner extends StatelessWidget {
  const AddonsLockedBanner({super.key});

  static const String text =
      'Addons are locked: your account\'s addon list could not be fetched, '
      'so the official addons are in use. Installing, updating and removing '
      'are disabled until it syncs.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Icon(Icons.lock_outline, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the failures of addon mutations as SnackBars: `Error` events whose
/// `source` is `AddonInstalled`, `AddonUninstalled` or `AddonUpgraded`
/// (already installed, protected, configuration required, addons locked).
/// Only the current route shows them, so a details screen pushed over the
/// addons list does not double up. Reads nothing but the source's name and
/// the error's message: event args can carry account details.
class AddonErrorSnackBars extends StatefulWidget {
  const AddonErrorSnackBars({super.key, required this.child});

  final Widget child;

  /// The event names whose failures this shows.
  static const Set<String> sources = {
    'AddonInstalled',
    'AddonUninstalled',
    'AddonUpgraded',
  };

  /// The message to show for [event], or null when it is not an addon
  /// mutation failure.
  static String? messageOf(RuntimeCoreEvent event) {
    if (event.name != 'Error') return null;
    final args = event.args;
    if (args is! Map<String, dynamic>) return null;
    final source = args['source'];
    if (source is! Map<String, dynamic> || !sources.contains(source['event'])) {
      return null;
    }
    final error = args['error'];
    final message = error is Map<String, dynamic> ? error['message'] : null;
    return message is String && message.isNotEmpty
        ? message
        : 'The addon could not be changed';
  }

  @override
  State<AddonErrorSnackBars> createState() => _AddonErrorSnackBarsState();
}

class _AddonErrorSnackBarsState extends State<AddonErrorSnackBars> {
  CoreClient? _client;
  StreamSubscription<CoreEvent>? _events;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _events?.cancel();
      _client = client;
      _events = client.events.listen(_onEvent);
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  void _onEvent(CoreEvent event) {
    if (event is! RuntimeCoreEvent || !mounted) return;
    final message = AddonErrorSnackBars.messageOf(event);
    if (message == null) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Opens [addon]'s configuration page (`…/configure`) in the system
/// browser through the [ExternalLinkScope]; a SnackBar when nothing could
/// open it. Nothing happens for an addon without one.
Future<void> openAddonConfiguration(
  BuildContext context,
  AddonDescriptor addon,
) async {
  final url = addon.configureUrl;
  if (url == null) return;
  final opener = ExternalLinkScope.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final opened = await opener.open(Uri.parse(url));
  if (!opened) {
    messenger?.showSnackBar(SnackBar(content: Text('Could not open $url')));
  }
}
