/// The words the downloads UI puts on a download: what to call one, what
/// state it is in, and why one was refused. Shared by the stream picker,
/// the episode list and the Downloads screen so all three say the same
/// thing about the same entry.
library;

import '../../core/core.dart';

/// Tooltip of the download button on a stream tile.
const String kDownloadTooltip = 'Download';

/// ... while its pin is being taken (a magnet resolves its metadata first).
const String kDownloadStartingTooltip = 'Starting download…';

/// ... once the file is whole on the device, where the button removes the
/// download. A tick sat here before and did nothing, which left the picker
/// that started a download with no way to undo one.
const String kDownloadDeleteTooltip = 'Downloaded — delete from this device';

/// ... when the server reported a reason it stopped; pressing it pins again.
const String kDownloadRetryTooltip = 'Download stopped — try again';

/// ... on a stream whose video is already kept from *another* release.
/// Pinning this one drops that pin, and the server deletes its file, so the
/// button must not read like a first download.
const String kDownloadReplaceTooltip =
    'Download instead — replaces the copy already kept';

/// What a download of [video] is called in a list: the title for a movie,
/// `Breaking Bad: S1E1 · Pilot` for an episode. It is stored with the entry,
/// so a Downloads screen has it without the meta.
String downloadName(MetaItem meta, VideoInfo? video) {
  if (video == null || video.id == meta.id) return meta.name;
  final label = [
    if (video.seasonEpisodeLabel.isNotEmpty) video.seasonEpisodeLabel,
    if (video.title.isNotEmpty) video.title,
  ].join(' · ');
  return label.isEmpty ? meta.name : '${meta.name}: $label';
}

/// One word (or two) for the state of [view], with the percentage while it
/// is arriving.
String downloadStateLabel(DownloadView view) => switch (view.state) {
  DownloadState.complete => 'Downloaded',
  DownloadState.downloading => 'Downloading${_percentSuffix(view)}',
  DownloadState.queued => 'Waiting to start',
  DownloadState.paused => 'Paused',
  DownloadState.error => 'Stopped',
};

/// ` 42%` when there is a fraction to report, nothing while there is not
/// (a magnet whose metadata has not resolved knows no length yet).
String _percentSuffix(DownloadView view) {
  final progress = view.progress;
  return progress == null ? '' : ' ${(progress * 100).round()}%';
}

/// What to say once a removal has come back. The entry is gone either
/// way, so what is worth reporting is what happened to the bytes: they
/// went, they stayed because they are another download's too, or they were
/// left as ordinary cache on purpose.
String downloadRemovedMessage(DownloadRemoveResult result, DownloadView view) =>
    switch (result) {
      // One torrent offered under two titles: the row goes, the bytes belong
      // to the other download.
      DownloadRemoveResult(removed: true, unpinned: false) =>
        'Removed. The file stays: another download uses it.',
      DownloadRemoveResult(deletedFiles: true) => 'Deleted ${view.name}.',
      _ => 'Removed ${view.name} from downloads.',
    };

/// The sentence to show for a refused pin. The server's own message is
/// client-safe (it never names a local path); a full disk gets the numbers
/// that message was built from, since "not enough space" is only useful
/// with "how much".
String downloadFailureMessage(DownloadFailure failure) {
  final message = failure.message.isEmpty
      ? 'The download was refused.'
      : failure.message;
  final required = failure.requiredBytes;
  final available = failure.availableBytes;
  if (failure.kind != DownloadFailureKind.insufficientSpace ||
      required == null ||
      available == null) {
    return message;
  }
  return '$message (needs ${DownloadView.humanSize(required)}, '
      '${DownloadView.humanSize(available)} free)';
}
