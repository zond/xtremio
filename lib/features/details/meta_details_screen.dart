import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../player/player_screen.dart';

/// One title: dispatches `Load MetaDetails` for [type]/[id] on mount, shows
/// the meta item and, underneath, every stream the installed addons return
/// for the selected video (the movie itself, or the engine's guess of the
/// episode to continue with). Tapping a playable stream opens the player.
class MetaDetailsScreen extends StatefulWidget {
  const MetaDetailsScreen({super.key, required this.type, required this.id});

  final String type;
  final String id;

  @override
  State<MetaDetailsScreen> createState() => _MetaDetailsScreenState();
}

class _MetaDetailsScreenState extends State<MetaDetailsScreen> {
  CoreClient? _client;
  CoreFieldNotifier? _details;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = CoreScope.of(context);
    if (_client != client) {
      _details?.dispose();
      _client = client;
      _details = CoreFieldNotifier(client, CoreField.metaDetails);
      client.dispatch(
        CoreActions.loadMetaDetails(type: widget.type, id: widget.id),
      );
    }
  }

  @override
  void dispose() {
    _client?.dispatch(CoreActions.unload(CoreField.metaDetails));
    _details?.dispose();
    super.dispose();
  }

  void _play(MetaDetailsState state, StreamGroup group, StreamInfo stream) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          stream: stream.json,
          streamRequest: group.request,
          metaRequest: state.metaRequest,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: _details!,
      builder: (context, json, _) {
        final state = json == null ? null : MetaDetailsState.fromJson(json);
        final meta = state?.meta;
        if (state == null || meta == null) {
          final error = state?.metaError;
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Could not load this title: ${error.message}',
                        textAlign: TextAlign.center,
                      ),
                    ),
            ),
          );
        }
        return Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 220,
                flexibleSpace: FlexibleSpaceBar(
                  title: Text(meta.name, maxLines: 1),
                  background: _Backdrop(url: meta.background),
                ),
              ),
              SliverToBoxAdapter(child: _MetaHeader(meta: meta)),
              SliverToBoxAdapter(child: _StreamsHeader(state: state)),
              if (state.streamGroups.isEmpty && state.isLoadingStreams)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
              for (final group in state.streamGroups)
                _StreamGroupSliver(
                  group: group,
                  onPlay: (stream) => _play(state, group, stream),
                ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
            ],
          ),
        );
      },
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    final url = this.url;
    return DecoratedBox(
      decoration: BoxDecoration(color: color),
      child: url == null
          ? null
          : Image.network(
              url,
              fit: BoxFit.cover,
              color: Colors.black45,
              colorBlendMode: BlendMode.darken,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
    );
  }
}

class _MetaHeader extends StatelessWidget {
  const _MetaHeader({required this.meta});

  final MetaItem meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final facts = [?meta.releaseInfo, ?meta.runtime, meta.type].join(' · ');
    final poster = meta.poster;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 110,
              height: 165,
              child: ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: poster == null
                    ? const Icon(Icons.movie_outlined)
                    : Image.network(
                        poster,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.movie_outlined),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(facts, style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Text(
                  meta.description ?? '',
                  style: theme.textTheme.bodyMedium,
                  maxLines: 7,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StreamsHeader extends StatelessWidget {
  const _StreamsHeader({required this.state});

  final MetaDetailsState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final video = state.selectedVideo;
    final meta = state.meta;
    final subtitle = video != null && meta != null && video.id != meta.id
        ? '${video.seasonEpisodeLabel} ${video.title}'.trim()
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Streams',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                if (subtitle != null)
                  Text(subtitle, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (state.isLoadingStreams)
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

class _StreamGroupSliver extends StatelessWidget {
  const _StreamGroupSliver({required this.group, required this.onPlay});

  final StreamGroup group;
  final ValueChanged<StreamInfo> onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = group.error;
    final streams = group.streams;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              group.addonLabel,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (error != null)
          SliverToBoxAdapter(
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.cloud_off_outlined),
              title: Text(error.message),
            ),
          )
        else if (group.content != null && streams.isEmpty)
          const SliverToBoxAdapter(
            child: ListTile(dense: true, title: Text('No streams')),
          ),
        SliverList.builder(
          itemCount: streams.length,
          itemBuilder: (context, index) {
            final stream = streams[index];
            return ListTile(
              enabled: stream.isPlayable,
              leading: Icon(_iconFor(stream.kind)),
              title: Text(stream.title),
              subtitle: stream.description != null && stream.name != null
                  ? Text(stream.description!)
                  : null,
              trailing: stream.isPlayable
                  ? const Icon(Icons.play_arrow)
                  : Text(stream.kind.label, style: theme.textTheme.labelSmall),
              onTap: stream.isPlayable ? () => onPlay(stream) : null,
            );
          },
        ),
      ],
    );
  }

  static IconData _iconFor(StreamKind kind) => switch (kind) {
    StreamKind.torrent || StreamKind.magnet => Icons.cloud_download_outlined,
    StreamKind.url => Icons.link,
    StreamKind.youtube => Icons.smart_display_outlined,
    StreamKind.external => Icons.open_in_new,
    StreamKind.playerFrame => Icons.web,
    StreamKind.archive => Icons.folder_zip_outlined,
    StreamKind.unknown => Icons.help_outline,
  };
}
