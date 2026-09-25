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
/// **One call reaches every granted file.** The `drive.file` grants
/// accumulate per user and per OAuth client and do not lapse -- measured
/// against the real API, not read in a document -- so an access token
/// minted now sees the files picked in earlier pairings too, and
/// [DriveFileLister.listFiles] needs no per-file request.
///
/// **A partial listing must delete nothing**, which is the one property
/// here worth arranging the types around. Drive pages its answer, and the
/// page after next is exactly where a television drops off its wifi. A
/// listing that stopped half way and was treated as the truth would read as
/// "the viewer deleted the rest", and would take rows off a list that
/// nothing can put back. So [DriveFilesListed] is *only* constructed at the
/// page that carries no `nextPageToken`: every other way out of
/// [XtremioDriveFileLister.listFiles] is a [_ListingRefused] thrown past
/// the half-built map, and [reloadLinkedDriveFiles] can only reach a write
/// through the [DriveFilesListed] arm of a switch. There is no value in
/// this file that means "some of the files".
///
/// **Nothing here is written down.** The refresh token goes into one
/// request body and the access token into one header; neither is logged,
/// neither is returned, and nothing in this file writes a line at all, so
/// there is no message for `redactSecrets` to have to catch (`AGENTS.md`,
/// "Never log auth material").
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'drive_account.dart';
import 'drive_link.dart';
import 'drive_pairing.dart';

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
  /// credential this hour (sixty, `drive-link/functions/index.js`). A limit
  /// that exists for cost rather than anything about this device.
  tooOften,

  /// Something answered a shape this build cannot read. Kept apart from
  /// [unreachable] because it means a version skew rather than a network,
  /// and **because more pages than this build will walk lands here**: that
  /// is a refusal, never a truncation.
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
/// paging ran to the end, so a stored file that is not in [filesById] is a
/// file the viewer can no longer reach -- which is what makes it safe for
/// [reloadLinkedDriveFiles] to drop a row on the strength of it.
final class DriveFilesListed extends DriveListing {
  const DriveFilesListed(this.filesById);

  /// Drive's own id to what Drive says about that file *now*.
  ///
  /// A file Drive named with something this build cannot read maps to the
  /// empty name, which [LinkedDriveFiles.reconciled] keeps the stored name
  /// for: present but unnamed is not a rename. A file Drive has not
  /// measured maps to a null height and duration, which is the ordinary
  /// case and not a failure.
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

/// How a page of the listing is asked for and read; thrown past a
/// half-built answer rather than returned, so that no partial map can be
/// mistaken for a whole one.
final class _ListingRefused implements Exception {
  const _ListingRefused(this.reason);

  final DriveListingFailure reason;
}

/// [DriveFileLister] over the pairing service and the real Drive API.
///
/// Two calls and not one. The app holds a refresh token and nothing else --
/// minting an access token needs the OAuth client secret, which a
/// sideloaded app cannot hold -- so this asks `POST /refresh` on the
/// pairing service first and spends the hour-long token it gets back on
/// `GET /drive/v3/files` straight after. The token is never stored: it is
/// good for an hour, this device has nowhere safe to put a second
/// credential, and a reload is over in a second.
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

  /// Where Drive's own API is, or null for [driveFiles] -- which is what
  /// the app builds this with, and the only value any shipped build has.
  ///
  /// A parameter for the reason [origin] is one and no further: the paging,
  /// the statuses and the two JSON types Google's fields arrive in are
  /// where this can go wrong, and a test proves those against a server on
  /// the loopback rather than against a stub of the parsing.
  final Uri? filesEndpoint;

  /// How long any one of the calls is given.
  final Duration timeout;

  /// Google's own listing endpoint.
  static final Uri driveFiles = Uri.https(
    'www.googleapis.com',
    '/drive/v3/files',
  );

  /// What is asked of each file, as Drive's field mask.
  ///
  /// `videoMediaMetadata` is the reason this is worth spelling out.
  /// Drive decodes an uploaded video server-side and keeps what it found,
  /// so the height that decides which resolution section a source belongs
  /// in is already sitting in the answer to a call being made anyway. The
  /// two alternatives are worse: a filename says `1080p` when somebody
  /// typed it, and a first-bytes probe of an MP4 misses the `moov` atom
  /// unless the file was written with faststart -- which is to say it fails
  /// on the files a probe would have been for.
  ///
  /// The object is asked for whole. `width` and `mimeType` come back with
  /// the rest and nothing stores them today; a mask that named only the two
  /// fields in use would have to be edited by whoever wants the aspect
  /// ratio, and there is no page of quota in it either way.
  static const String fields =
      'nextPageToken,files(id,name,mimeType,'
      'videoMediaMetadata(width,height,durationMillis))';

  /// How many files one page asks for. Drive's own maximum is 1000; a
  /// hundred keeps one answer small enough to read in a couple of
  /// kilobytes and a viewer's whole list is normally one page.
  static const int pageSize = 100;

  /// How many pages are walked before the answer is refused outright.
  ///
  /// **A cap and not a trim.** Past this the listing is
  /// [DriveListingFailure.notUnderstood] and nothing is written: a
  /// truncated listing is exactly the partial answer this file exists to
  /// keep away from the store. Fifty pages is five thousand files, against
  /// a hundred per pairing, so reaching it means a page token that never
  /// ends rather than a large Drive.
  static const int maxPages = 50;

  /// How much of one answer is read before it is called malformed. A page
  /// of a hundred ids and names is a few tens of kilobytes.
  static const int _maxBodyBytes = 512 * 1024;

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
      // Every way a socket can fail is one sentence from an armchair, and
      // the exception's own text is not it -- the call it came out of was
      // handed a credential.
      return const DriveListingFailed(DriveListingFailure.unreachable);
    } finally {
      client.close(force: true);
    }
  }

  /// An access token for [refreshToken], or a refusal thrown.
  Future<String> _accessToken(HttpClient client, String refreshToken) async {
    final answer = await _send(
      client,
      'POST',
      Uri.parse('$origin/refresh'),
      body: {'refreshToken': refreshToken},
    ).timeout(timeout);
    if (answer.statusCode == HttpStatus.tooManyRequests) {
      await answer.drain<void>();
      throw const _ListingRefused(DriveListingFailure.tooOften);
    }
    final json = await _json(answer);
    if (answer.statusCode != HttpStatus.ok) {
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
  /// Nothing Google answers here is read as terminal. A `401` on a token
  /// minted a moment ago is a good deal more likely to be a proxy or a
  /// clock than a revoked grant, and reading it as [pairAgain] would drop
  /// the viewer's credential over it -- so only the pairing service's own
  /// `pairAgain` says that, and everything else is worth trying again.
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
      },
    );
    final answer = await _send(
      client,
      'GET',
      url,
      bearer: accessToken,
    ).timeout(timeout);
    final json = await _json(answer);
    if (answer.statusCode != HttpStatus.ok) {
      throw const _ListingRefused(DriveListingFailure.unreachable);
    }
    final page = parseDriveFilesPage(json);
    if (page == null) {
      throw const _ListingRefused(DriveListingFailure.notUnderstood);
    }
    return page;
  }

  static Future<HttpClientResponse> _send(
    HttpClient client,
    String method,
    Uri url, {
    Map<String, Object?>? body,
    String? bearer,
  }) async {
    final request = await client.openUrl(method, url);
    // Nothing here follows a redirect: both ends answer JSON directly, and
    // a followed redirect is how an `Authorization` header ends up at a
    // host nobody meant to send it to. A redirect reads as a non-`200`,
    // which is [DriveListingFailure.unreachable].
    request.followRedirects = false;
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    return request.close();
  }

  static Future<Map<String, dynamic>?> _json(HttpClientResponse answer) async {
    final bytes = <int>[];
    var tooBig = false;
    await for (final chunk in answer) {
      // Read to the end even past the cap, so the connection is finished
      // with rather than abandoned half-read.
      if (tooBig) continue;
      bytes.addAll(chunk);
      tooBig = bytes.length > _maxBodyBytes;
    }
    if (tooBig) return null;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }
}

/// One page of Drive's `files.list` as this build reads it: what is on the
/// page, and the token for the next page or null when this was the last.
/// **Null** for a body that is not a page at all.
///
/// Visible for tests, the way [parseDriveOpenAnswer] is, and for the same
/// reason: the reading is where the surprises are and the fetching is not
/// something a test may do.
///
/// A row with no id is skipped -- the id is what everything is keyed on --
/// and a row with no readable name is kept under the empty name rather than
/// skipped, because leaving it out means *gone* and gone removes somebody's
/// row.
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
    final measured = one['videoMediaMetadata'];
    files[id.trim()] = (
      name: name is String ? name : '',
      // Absent for anything Drive has not processed or could not decode,
      // which is an ordinary answer and not a malformed one -- so it is
      // null here, and nothing downstream may require it.
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
/// Zero and below are nothing measured rather than a measurement: a height
/// of nought is not a video, it is a field somebody filled in.
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
/// Both counts are worth having because both are worth saying out loud: a
/// reload that changed nothing has to say so, or it is a button that looks
/// broken and gets pressed again.
final class DriveReloadDone extends DriveReloaded {
  const DriveReloadDone({required this.renamed, required this.removed});

  /// How many stored files Drive now gives a different name.
  final int renamed;

  /// How many stored files were not in the listing at all -- deleted,
  /// binned, or no longer shared with this app.
  final int removed;

  bool get changedNothing => renamed == 0 && removed == 0;

  @override
  String toString() => 'DriveReloadDone(renamed: $renamed, removed: $removed)';
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
///    and loses the match its old name earned -- the rename is the one
///    thing a viewer can do about a file that matched the wrong title or
///    nothing at all, and the note above the list tells them to do it, so
///    the match has to be made again. That dropping is
///    [LinkedDriveFile.reconciledWith]'s doing rather than a step here, so
///    no caller can write a new name and keep a stale match.
///  * a stored file Drive has **measured** since it was linked takes the
///    height and duration it measured. Nothing reads them yet; they are
///    recorded now because they arrive in the answer to a call being made
///    anyway, and because the alternatives are a filename and a probe that
///    both lie (see [LinkedDriveFile.height]).
///  * a stored file **absent** from the listing loses its row: the grant is
///    gone or the file is, and a row that cannot play is worse than no row.
///  * **nothing is added.** The listing reaches files this install never
///    stored -- picked in a pairing on another device, or before the
///    preferences were cleared -- and a list the viewer built by picking is
///    not a mirror of their Drive. (There is no per-file unlink to fight
///    with: [DriveAccount.unlink] is the whole account, and it takes the
///    credential with it. Adding rows back would still be this screen
///    inventing files nobody picked *here*.)
///
/// One write, at the end, from a listing that is complete by construction:
/// the failed arm returns before [DriveAccount.noteReconciled] is in
/// reach.
Future<DriveReloaded> reloadLinkedDriveFiles({
  required DriveAccount account,
  required DriveFileLister lister,
}) async {
  final token = account.refreshToken;
  if (token == null || token.isEmpty) {
    return const DriveReloadRefused(DriveListingFailure.notLinked);
  }
  final listing = await lister.listFiles(refreshToken: token);
  switch (listing) {
    case DriveListingFailed(:final reason):
      // The same one side effect [openLinkedDriveFile] has, for the same
      // reason: a grant the service has rejected is terminal, and every
      // screen that reads the state should already know by the time this
      // returns.
      if (reason == DriveListingFailure.pairAgain) {
        await account.notePairAgain();
      }
      return DriveReloadRefused(reason);
    case DriveFilesListed(:final filesById):
      final before = account.files;
      final after = before.reconciled(filesById);
      var renamed = 0;
      for (final entry in after.entries) {
        if (before.forFile(entry.fileId)?.name != entry.name) renamed++;
      }
      await account.noteReconciled(after);
      return DriveReloadDone(
        renamed: renamed,
        removed: before.entries.length - after.entries.length,
      );
  }
}

/// What a viewer is told about [outcome]. One sentence, always -- including
/// for the reload that found nothing to do, which is the sentence that
/// keeps the button from looking inert.
String driveReloadMessage(DriveReloaded outcome) => switch (outcome) {
  DriveReloadDone(:final renamed, :final removed) when renamed + removed == 0 =>
    'Nothing has changed in Drive since these files were linked.',
  DriveReloadDone(:final renamed, removed: 0) =>
    '${_files(renamed)} renamed in Drive.',
  DriveReloadDone(renamed: 0, :final removed) =>
    'Removed ${_files(removed)} this device can no longer reach.',
  DriveReloadDone(:final renamed, :final removed) =>
    '${_files(renamed)} renamed in Drive, and removed '
        '${_files(removed)} this device can no longer reach.',
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
