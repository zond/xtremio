/// Asking Drive what the linked files are called *now*, and writing the
/// answer over what this device last heard.
///
/// **The stored name is a snapshot and the API is not.** A
/// [LinkedDriveFile] carries the name the Picker handed over at the moment
/// it was picked; `GET /drive/v3/files` answers with each file's current
/// metadata. So one listing is the whole of a reconciliation: a file
/// renamed in Drive comes back under its new name, and a file that has been
/// deleted, or whose grant has been withdrawn, does not come back at all.
///
/// **One call reaches every granted file.** The `drive.file` grants accumulate
/// per user and per OAuth client and do not lapse (see [DriveAccount], "One
/// token, not one per file"). So an access token minted now sees the files
/// picked in earlier pairings too, and [DriveFileLister.listFiles] needs no
/// per-file request.
///
/// **A partial listing must delete nothing.** That is the one property here
/// worth arranging the types around. Drive pages its answer, and the page after
/// next is exactly where a television drops off its wifi. A listing that
/// stopped half way and was treated as the truth would read as "the viewer
/// deleted the rest", and would take rows off a list that nothing can put back.
/// So [DriveFilesListed] is *only* constructed at the page that carries no
/// `nextPageToken`. Every other way out of [XtremioDriveFileLister.listFiles]
/// is a [_ListingRefused] thrown past the half-built map, and
/// [reloadLinkedDriveFiles] can only reach a write through the
/// [DriveFilesListed] arm of a switch. No value in this file means "some of the
/// files".
///
/// **Nothing here is written down.** The refresh token goes into one request
/// body and the access token into one header. Neither is logged or returned,
/// and nothing in this file writes a line at all, so there is no message for
/// `redactSecrets` to catch (`AGENTS.md`, "Never log auth material").
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'drive_account.dart';
import 'drive_link.dart';
import 'drive_pairing.dart';
import 'json_exchange.dart';

/// Why a listing could not be had. Each is a different sentence to a
/// viewer, which is why none of them is a message from somewhere else.
enum DriveListingFailure {
  /// **Terminal.** The pairing service says the grant is gone: revoked, or
  /// expired. The viewer pairs again from their phone; nothing is
  /// reconciled, and the list of files survives, because those files are
  /// what a new token will reach.
  pairAgain,

  /// Nothing is stored for this device to ask with. Not a failure of the
  /// call -- the caller asked with no credential.
  notLinked,

  /// The pairing service or Google could not be reached, or would not
  /// answer. Worth pressing again; the grant may be perfectly good.
  unreachable,

  /// The pairing service is refusing to mint any more tokens for this
  /// credential this hour (sixty, `xtremio-xervice/functions/index.js`). That
  /// limit exists for cost, not because of anything about this device.
  tooOften,

  /// Something answered a shape this build cannot read. It is kept apart from
  /// [unreachable] because it means a version skew rather than a network.
  /// **More pages than this build will walk also land here**: that is a
  /// refusal, never a truncation.
  notUnderstood,
}

/// What one listing came back with. Two cases, and the absence of a third
/// is the point: see the library comment.
sealed class DriveListing {
  const DriveListing();
}

/// **Every** file the credential reaches, as Drive names them now.
///
/// The invariant this type carries is completeness. A value of it means the
/// paging ran to the end. So a stored file that is not in [filesById] is a file
/// the viewer can no longer reach, which makes it safe for
/// [reloadLinkedDriveFiles] to drop a row on the strength of it.
final class DriveFilesListed extends DriveListing {
  const DriveFilesListed(this.filesById);

  /// Drive's own id to what Drive says about that file *now*.
  ///
  /// A file Drive named with something this build cannot read maps to the empty
  /// name. [LinkedDriveFiles.reconciled] keeps the stored name for it: present
  /// but unnamed is not a rename. A file Drive has not measured maps to a null
  /// height and duration, which is the ordinary case and not a failure.
  final Map<String, DriveFileFacts> filesById;
}

/// No listing, and which of the reasons. **Nothing is reconciled from
/// this**: a failure is not a shorter list.
final class DriveListingFailed extends DriveListing {
  const DriveListingFailed(this.reason);

  final DriveListingFailure reason;
}

/// Asking Drive for the files one credential reaches.
///
/// Behind an interface for the reason [DriveFileOpener] is: a widget test
/// walks the button that calls this, and a widget test must reach neither
/// the pairing service nor Google.
abstract interface class DriveFileLister {
  /// Every file [refreshToken] reaches, or the reason there is no list.
  /// **Never throws**: every outcome is a value the caller can draw.
  Future<DriveListing> listFiles({required String refreshToken});
}

/// How a page of the listing is asked for and read. It is thrown past a
/// half-built answer rather than returned, so that no partial map can be
/// mistaken for a whole one.
final class _ListingRefused implements Exception {
  const _ListingRefused(this.reason);

  final DriveListingFailure reason;
}

/// [DriveFileLister] over the pairing service and the real Drive API.
///
/// Two calls and not one. The app holds a refresh token and nothing else, since
/// minting an access token needs the OAuth client secret, which a sideloaded
/// app cannot hold. So this asks `POST /refresh` on the pairing service first,
/// and spends the hour-long token it gets back on `GET /drive/v3/files`
/// straight after. The token is never stored: it is good for an hour, this
/// device has nowhere safe to put a second credential, and a reload is over in
/// a second.
@immutable
class XtremioDriveFileLister implements DriveFileLister {
  const XtremioDriveFileLister({
    this.origin = XtremioDrivePairingService.defaultOrigin,
    this.filesEndpoint,
    this.timeout = const Duration(seconds: 15),
  });

  /// Where the pairing service lives; the same origin the pairing itself
  /// used, written down in one place ([XtremioDrivePairingService]).
  final String origin;

  /// Where Drive's own API is, or null for [driveFiles]. The app builds this
  /// with null, the only value any shipped build has.
  ///
  /// It is a parameter for the reason [origin] is one, and no further. The
  /// paging, the statuses and the two JSON types Google's fields arrive in are
  /// where this can go wrong. A test proves those against a server on the
  /// loopback rather than against a stub of the parsing.
  final Uri? filesEndpoint;

  /// How long any one of the calls is given, its body included.
  final Duration timeout;

  /// Google's own listing endpoint.
  static final Uri driveFiles = Uri.https(
    'www.googleapis.com',
    '/drive/v3/files',
  );

  /// What is asked of each file, as Drive's field mask.
  ///
  /// `videoMediaMetadata` is the reason this is worth spelling out. Drive
  /// decodes an uploaded video server-side and keeps what it found. So the
  /// height that decides a source's resolution section is already in the answer
  /// to a call being made anyway. The two alternatives are worse. A filename
  /// says `1080p` when somebody typed it. A first-bytes probe of an MP4 misses
  /// the `moov` atom unless the file was written with faststart, so it fails on
  /// exactly the files a probe would have been for.
  ///
  /// The object is asked for whole. `width` and `mimeType` come back with the
  /// rest, and nothing stores them today. A mask that named only the two fields
  /// in use would have to be edited by whoever wants the aspect ratio, and it
  /// would make no difference to quota either way.
  static const String fields =
      'nextPageToken,files(id,name,mimeType,'
      'videoMediaMetadata(width,height,durationMillis))';

  /// Asked of every page. A file a viewer picked out of a shared drive is
  /// granted like any other, and `files.list` leaves shared drives out unless
  /// told otherwise.
  static const Map<String, String> allDrives = {
    'supportsAllDrives': 'true',
    'includeItemsFromAllDrives': 'true',
  };

  /// How many files one page asks for: Drive's own maximum. A reload now adds
  /// what other devices picked, so the listing is the account's whole set of
  /// picks rather than this device's handful. One page of a thousand is fewer
  /// round trips than ten of a hundred.
  static const int pageSize = 1000;

  /// How many pages are walked before the answer is refused outright.
  ///
  /// **A cap and not a trim.** Past this the listing is
  /// [DriveListingFailure.notUnderstood], and nothing is written. A truncated
  /// listing is exactly the partial answer this file exists to keep away from
  /// the store. Fifty pages is five thousand files, against a hundred per
  /// pairing, so reaching the cap means a page token that never ends rather
  /// than a large Drive.
  static const int maxPages = 5;

  /// How much of one answer is read before it is called malformed. A page
  /// of a thousand ids, names and measurements is a few hundred kilobytes.
  static const int _maxBodyBytes = 4 * 1024 * 1024;

  @override
  Future<DriveListing> listFiles({required String refreshToken}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final accessToken = await _accessToken(client, refreshToken);
      final files = <String, DriveFileFacts>{};
      String? pageToken;
      for (var page = 0; page < maxPages; page++) {
        final (listed, next) = await _page(client, accessToken, pageToken);
        files.addAll(listed);
        // The one construction of a complete answer, and it is reachable
        // only from the page that says there are no more.
        if (next == null) return DriveFilesListed(files);
        pageToken = next;
      }
      throw const _ListingRefused(DriveListingFailure.notUnderstood);
    } on _ListingRefused catch (refused) {
      return DriveListingFailed(refused.reason);
    } on Object {
      // Every way a socket can fail is one sentence from an armchair. The
      // exception's own text is not that sentence, and the call it came out of
      // was handed a credential.
      return const DriveListingFailed(DriveListingFailure.unreachable);
    } finally {
      client.close(force: true);
    }
  }

  /// An access token for [refreshToken], or a refusal thrown.
  Future<String> _accessToken(HttpClient client, String refreshToken) async {
    final (status, json) = await _exchange(
      client,
      'POST',
      Uri.parse('$origin/refresh'),
      body: {'refreshToken': refreshToken},
    );
    if (status == HttpStatus.tooManyRequests) {
      throw const _ListingRefused(DriveListingFailure.tooOften);
    }
    if (status != HttpStatus.ok) {
      // `pairAgain` is the service saying Google answered `invalid_grant`:
      // the viewer revoked us, or the consent screen is still in Testing.
      // Nothing else is read as terminal, because a wrong guess here
      // deletes the credential.
      throw _ListingRefused(
        json?['pairAgain'] == true
            ? DriveListingFailure.pairAgain
            : DriveListingFailure.unreachable,
      );
    }
    final token = json?['accessToken'];
    if (token is! String || token.isEmpty) {
      throw const _ListingRefused(DriveListingFailure.notUnderstood);
    }
    return token;
  }

  /// One page: the names on it, and the token for the next page or null
  /// when this was the last.
  ///
  /// Nothing Google answers here is read as terminal. A `401` on a token minted
  /// a moment ago is far more likely to be a proxy or a clock than a revoked
  /// grant. Reading it as [pairAgain] would drop the viewer's credential over
  /// it. So only the pairing service's own `pairAgain` says that, and
  /// everything else is worth trying again.
  Future<(Map<String, DriveFileFacts>, String?)> _page(
    HttpClient client,
    String accessToken,
    String? pageToken,
  ) async {
    final url = (filesEndpoint ?? driveFiles).replace(
      queryParameters: {
        // A file in the bin cannot be played, so it is not in the listing
        // and its row goes the way a deleted file's does.
        'q': 'trashed = false',
        'fields': fields,
        'pageSize': '$pageSize',
        'pageToken': ?pageToken,
        ...allDrives,
      },
    );
    final (status, json) = await _exchange(
      client,
      'GET',
      url,
      bearer: accessToken,
    );
    if (status != HttpStatus.ok) {
      throw const _ListingRefused(DriveListingFailure.unreachable);
    }
    final page = parseDriveFilesPage(json);
    if (page == null) {
      throw const _ListingRefused(DriveListingFailure.notUnderstood);
    }
    return page;
  }

  /// One request and its whole body, within [timeout]: a body that stalls
  /// part-way is as much a hang as a connection that never answers.
  ///
  /// A redirect is not followed (see [sendWithoutRedirects]) and reads as
  /// a non-`200`, which is [DriveListingFailure.unreachable].
  Future<(int, Map<String, dynamic>?)> _exchange(
    HttpClient client,
    String method,
    Uri url, {
    Map<String, Object?>? body,
    String? bearer,
  }) {
    Future<(int, Map<String, dynamic>?)> exchange() async {
      final answer = await sendWithoutRedirects(
        client,
        method,
        url,
        body: body,
        bearer: bearer,
      );
      final json = await readJsonObject(answer, maxBytes: _maxBodyBytes);
      return (answer.statusCode, json);
    }

    return exchange().timeout(timeout);
  }
}

/// One page of Drive's `files.list` as this build reads it: what is on the
/// page, and the token for the next page or null when this was the last.
/// **Null** for a body that is not a page at all.
///
/// Visible for tests, like [parseDriveOpenAnswer], and for the same reason: the
/// reading is where the surprises are, and a test may not do the fetching.
///
/// A row with no id is skipped, since the id is what everything is keyed on. A
/// row with no readable name is kept under the empty name rather than skipped,
/// because leaving it out means *gone*, and gone removes somebody's row.
(Map<String, DriveFileFacts>, String?)? parseDriveFilesPage(Object? json) {
  if (json is! Map) return null;
  final listed = json['files'];
  if (listed is! List) return null;
  final files = <String, DriveFileFacts>{};
  for (final one in listed) {
    if (one is! Map) continue;
    final id = one['id'];
    if (id is! String || id.trim().isEmpty) continue;
    final name = one['name'];
    final mime = one['mimeType'];
    final measured = one['videoMediaMetadata'];
    files[id.trim()] = (
      name: name is String ? name : '',
      mimeType: mime is String ? mime : '',
      // Absent for anything Drive has not processed or could not decode. That
      // is an ordinary answer and not a malformed one, so it is null here, and
      // nothing downstream may require it.
      height: _measured(measured, 'height'),
      durationMillis: _measured(measured, 'durationMillis'),
    );
  }
  final next = json['nextPageToken'];
  return (files, next is String && next.isNotEmpty ? next : null);
}

/// One number out of Drive's `videoMediaMetadata`, or null when Drive
/// measured nothing this build can use.
///
/// **Two JSON types, and that is Google's doing rather than a defensive
/// habit.** `width` and `height` are 32-bit and arrive as numbers;
/// `durationMillis` is 64-bit, and the JSON mapping for a 64-bit field is a
/// *string*. A build that read only one of the two would drop the duration
/// of every file and never say so.
///
/// Zero and below mean nothing was measured: a height of nought is not a video
/// but a field somebody filled in.
int? _measured(Object? metadata, String field) {
  if (metadata is! Map) return null;
  final value = metadata[field];
  final number = value is int
      ? value
      : (value is String ? int.tryParse(value) : null);
  return number == null || number <= 0 ? null : number;
}

/// What one press of **Reload** came to.
sealed class DriveReloaded {
  const DriveReloaded();
}

/// The listing was complete, and the stored list now says what Drive says.
///
/// Both counts are worth having because both are worth saying out loud. A
/// reload that changed nothing has to say so, or it is a button that looks
/// broken and gets pressed again.
final class DriveReloadDone extends DriveReloaded {
  const DriveReloadDone({
    required this.renamed,
    required this.removed,
    this.added = 0,
  });

  /// How many stored files Drive now gives a different name.
  final int renamed;

  /// How many stored files were not in the listing at all -- deleted,
  /// binned, or no longer shared with this app.
  final int removed;

  /// How many files the listing named that were not stored here.
  final int added;

  @override
  String toString() =>
      'DriveReloadDone(renamed: $renamed, removed: $removed, added: $added)';
}

/// Nothing was reconciled, and this is why. **The stored list is exactly
/// as it was**, including after a listing that failed on its fourth page.
final class DriveReloadRefused extends DriveReloaded {
  const DriveReloadRefused(this.reason);

  final DriveListingFailure reason;

  @override
  String toString() => 'DriveReloadRefused($reason)';
}

/// Reconciles every stored file against what Drive says now.
///
/// What it does, and the whole of it:
///
///  * a stored file Drive gives a **different name** takes the new name,
///    and loses the match its old name earned. A rename is the one thing a
///    viewer can do about a file that matched the wrong title or nothing at
///    all, and the note above the list tells them to do it, so the match
///    has to be made again. [LinkedDriveFile.reconciledWith] drops the
///    match, not a step here, so no caller can write a new name and keep a
///    stale match.
///  * a stored file Drive has **measured** since it was linked takes the
///    height and duration it measured. The height decides the file's
///    resolution section on its details page; the duration is not read
///    yet. Both are recorded because they arrive in the answer to a call
///    being made anyway, and because the alternatives are a filename and a
///    probe that both lie (see [LinkedDriveFile.height]).
///  * a stored file **absent** from the listing loses its row: the grant is
///    gone or the file is, and a row that cannot play is worse than no row.
///  * a file in the listing that is **not stored** is added
///    ([LinkedDriveFiles.addingListed]). The listing is every file the
///    Google account picked through this client, on any device, so a file
///    picked on the phone appears here. That is what a grant shared through
///    the account's vault is for. Folders are left out.
///
/// It makes one write, at the end, from a listing that is complete by
/// construction. The failed arm returns before [DriveAccount.noteReconciled] is
/// in reach.
///
/// A pairing that lands while the listing is out changes the grant under it.
/// The answer is then about the old grant, and reconciling it would drop the
/// files the new pairing just linked, since they are in no listing the old
/// grant could make. So the listing is asked again, once, with the new token.
Future<DriveReloaded> reloadLinkedDriveFiles({
  required DriveAccount account,
  required DriveFileLister lister,
}) => _reload(account, lister, again: true);

Future<DriveReloaded> _reload(
  DriveAccount account,
  DriveFileLister lister, {
  required bool again,
}) async {
  final token = account.refreshToken;
  if (token == null || token.isEmpty) {
    return const DriveReloadRefused(DriveListingFailure.notLinked);
  }
  final listing = await lister.listFiles(refreshToken: token);
  if (again && account.refreshToken != token) {
    return _reload(account, lister, again: false);
  }
  switch (listing) {
    case DriveListingFailed(:final reason):
      // The same one side effect [openLinkedDriveFile] has, for the same
      // reason: a grant the service has rejected is terminal, and every
      // screen that reads the state should already know by the time this
      // returns.
      if (reason == DriveListingFailure.pairAgain) {
        await account.notePairAgain(ifToken: token);
      }
      return DriveReloadRefused(reason);
    case DriveFilesListed(:final filesById):
      final before = account.files;
      final reconciled = before.reconciled(filesById);
      var renamed = 0;
      for (final entry in reconciled.entries) {
        if (before.forFile(entry.fileId)?.name != entry.name) renamed++;
      }
      final after = reconciled.addingListed(filesById, account.now().toUtc());
      await account.noteReconciled(after);
      return DriveReloadDone(
        renamed: renamed,
        removed: before.entries.length - reconciled.entries.length,
        added: after.entries.length - reconciled.entries.length,
      );
  }
}

/// What a viewer is told about [outcome]. It is always one sentence, including
/// for the reload that found nothing to do, which is the sentence that keeps
/// the button from looking inert.
String driveReloadMessage(DriveReloaded outcome) => switch (outcome) {
  DriveReloadDone(:final renamed, :final removed, :final added)
      when renamed + removed + added == 0 =>
    'Nothing has changed in Drive since these files were linked.',
  DriveReloadDone(:final renamed, :final removed, :final added) =>
    '${_sentence([if (added > 0) 'added ${_files(added)} picked on another device', if (renamed > 0) '${_files(renamed)} renamed in Drive', if (removed > 0) 'removed ${_files(removed)} this device can no longer reach'])}.',
  DriveReloadRefused(:final reason) => switch (reason) {
    DriveListingFailure.pairAgain =>
      'This device is no longer linked to that Google account. Link it '
          'again to see your files.',
    DriveListingFailure.notLinked =>
      'No Google account is linked to this device yet.',
    DriveListingFailure.unreachable =>
      'Google could not be reached just now. Nothing has changed; try again '
          'in a moment.',
    DriveListingFailure.tooOften =>
      'This link has been refreshed too many times in the last hour. '
          'Nothing has changed; try again later.',
    DriveListingFailure.notUnderstood =>
      'Drive answered something this app could not read. Nothing has '
          'changed.',
  },
};

String _files(int count) => count == 1 ? '1 file' : '$count files';

/// [parts] as one sentence: "a", "a, and b", "a, b, and c", capitalised.
String _sentence(List<String> parts) {
  final joined = parts.length < 2
      ? parts.join()
      : '${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}';
  return joined.isEmpty
      ? joined
      : joined[0].toUpperCase() + joined.substring(1);
}
