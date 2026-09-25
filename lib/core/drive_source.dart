/// A linked Google Drive file as a *row in a sources list*, which is a
/// different thing from the same file as something a player can open.
///
/// [driveStreamJson] in `drive_playback.dart` is the second of those, and it
/// cannot be the first: it needs a [DriveFilePlayable], which only exists
/// after the embedded server has opened the file and minted a key for it.
/// A details screen has to draw the row *before* anybody presses it -- and
/// must not open a file nobody asked for, since opening one spends the
/// account's grant and starts a byte source on the server.
///
/// So the row is drawn from what is already stored: the name Drive gave the
/// file, and its id. That is enough for everything the list does with a row
/// -- the lead line, the resolution it is sectioned under, the pills
/// ([StreamFacts]) -- because all of those are read out of the name and the
/// name is all a Drive file has. A file called `holiday video 2.avi` reads
/// back no resolution, no size and no seeders, and so draws no pills at all.
/// That is the correct rendering of a file nothing is known about, not a
/// gap to fill with placeholders.
library;

import 'drive_link.dart';
import 'drive_playback.dart';
import 'state/stream.dart';

/// The scheme of [driveSourceUrl].
///
/// **Nothing ever fetches it**, and it is spelled so that nothing could: no
/// resolver in this app or in stremio-core knows this scheme, and a Drive
/// file's real URL is a loopback `/drive/stream/{key}` that does not exist
/// until the press. The URL is here to give the row the one thing a sources
/// list needs of every row and cannot invent -- a stable identity, so that
/// [StreamInfo.sourceKey] tells two linked files apart and never folds one
/// into an addon's answer -- and to make [StreamInfo.kind] say `url`, which
/// is what this file becomes the moment it is opened.
///
/// The press goes to `openLinkedDriveFile` and [driveStreamJson] instead
/// (see `_MetaDetailsScreenState._playRow`), so this string reaches no
/// player, no log line and no request. It carries the file id, which is not
/// a credential -- it is already in the preferences file -- and carries
/// nothing else.
const String driveSourceScheme = 'xtremio-drive';

/// The identity of [file] as a sources list keys a row on. See
/// [driveSourceScheme] for why this is a URL that is never fetched.
String driveSourceUrl(LinkedDriveFile file) =>
    '$driveSourceScheme:${file.fileId}';

/// [file] as the stream JSON a sources row is drawn from.
///
/// `name` is the file's own name, which is what the lead line falls back
/// to, and `behaviorHints.filename` is the same name again -- the branch
/// [StreamPresentation] leads with, and the one that takes the container
/// extension off before drawing it. A file Drive gave no name for leads
/// with its id, the way the Remote list's tile does: an id a viewer can
/// read off the screen beats a blank row.
///
/// There is deliberately **no `description`**. The addons write their stats
/// line there and the row draws it whole under the lead; a Drive file has
/// no such line, and putting `Google Drive` in it would draw the source
/// where the addon's own words go -- and then draw it a second time as the
/// provenance line the sectioned layout adds. The source is said once, as
/// the addon slot ([StreamFacts.addonName]), which is the slot that means
/// "where this came from".
Map<String, dynamic> driveSourceJson(LinkedDriveFile file) => {
  'url': driveSourceUrl(file),
  'name': file.name.isEmpty ? file.fileId : file.name,
  if (file.name.isNotEmpty) 'behaviorHints': {'filename': file.name},
};

/// [driveSourceJson] as the view the list reads.
StreamInfo driveSourceStream(LinkedDriveFile file) =>
    StreamInfo(driveSourceJson(file));
