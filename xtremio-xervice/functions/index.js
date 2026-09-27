/**
 * Pairing a television with files in a Google Drive, over a QR code.
 *
 * The television cannot run the Google Picker -- it is web-only -- and it
 * cannot hold the OAuth client secret, because it is an app anybody can
 * unpack. So the phone does the picking and this function does the two
 * things that need the secret: turning an authorization code into tokens,
 * and turning a refresh token into an access token.
 *
 * The flow, and what is stored at each step:
 *
 *   1. app   POST /session            -> a session doc, `pending`, 10 min
 *   2. TV    shows a QR for /link?s=<id>; a phone opens it itself
 *   3. phone signs in, redirected to  /oauth/callback?code&state=<id>
 *   4. here  exchanges the code, writes the refresh token on the session
 *   5. phone picks files, POST /session/<id>/files, session becomes `ready`
 *   6. app   GET /session/<id>        -> the tokens and the files, ONCE
 *   7. app   POST /refresh            -> a fresh access token, later
 *
 * The session is deleted the moment the television collects it, so the
 * only thing this service stores long-term is nothing at all. A refresh
 * token lives here for the minutes between a phone signing in and a
 * television picking it up.
 *
 * **There is deliberately no App Check.** It attests that a request comes
 * from a build Google Play distributed, and every install of this app is
 * sideloaded -- so it would reject every real user while stopping nobody:
 * `/refresh` is useless without a refresh token this client issued, and
 * the only way to hold one is to have completed this flow with your own
 * account. What is left to defend against is cost, which is what the rate
 * limits below are for.
 */
const {onRequest} = require('firebase-functions/v2/https');
const {defineSecret} = require('firebase-functions/params');
const {initializeApp} = require('firebase-admin/app');
const {getFirestore, FieldValue} = require('firebase-admin/firestore');
const crypto = require('crypto');
const express = require('express');

const CLIENT_ID = defineSecret('OAUTH_CLIENT_ID');
const CLIENT_SECRET = defineSecret('OAUTH_CLIENT_SECRET');

initializeApp();
const db = getFirestore();

/** How long a viewer has to scan the code and pick something. */
const SESSION_MINUTES = 10;

/**
 * The most files one pairing may carry.
 *
 * The Picker's multiselect has no bound of its own, and a session document
 * has Firestore's: one megabyte. A row is a file id, a name of at most 255
 * characters and a mime type, so a hundred of them is about thirty
 * kilobytes and nowhere near it. The number is not really about bytes
 * though -- it is a whole show's worth of episodes, and a pick larger than
 * that is somebody selecting everything rather than choosing something.
 * Over the limit is refused and said out loud, never silently trimmed: a
 * viewer who picked forty files and got thirty would have no way to know.
 */
const MAX_FILES = 100;

/**
 * Where the pick page sends a phone's browser once the picking is done.
 *
 * Only for a pairing a phone asked for (`shape` on `POST /session`), which
 * is the app saying "I opened this browser myself, hand the viewer back when
 * you are finished". A television's viewer looks up at the screen and is sent
 * nowhere; a desktop's is looking at this page and has nowhere to be sent,
 * because the scheme's registration there is installed by hand or not at all.
 * See [SHAPES].
 *
 * It is host-less on purpose, and the app **does not act on it**: a
 * `stremio://` link with no host is exactly the shape the app already
 * drops (`lib/shell/deep_link.dart`, and `docs/DEEP_LINKS.md` -- those are
 * the official clients' own in-app routes). So this adds no second meaning
 * to a scheme whose one meaning is "open that addon's details", and a
 * launch link the platform replays on a cold start days later is dropped
 * then too, because it was never acted on in the first place. The whole
 * effect of it is the platform bringing the app forward, which is what a
 * hand-back is.
 *
 * Written down here rather than taken from the app: this is a URL a page
 * on this origin navigates to, and a client-supplied one would be an open
 * redirect with a signed-in viewer in front of it. The app's own copy of
 * the constant is `drivePairingHandBackLink` in
 * `lib/core/drive_pairing.dart`, which nothing but a test reads.
 */
const HAND_BACK_LINK = 'stremio:///pair';

/** What the app asks for, and the only thing it can ask for without a
 * Google security assessment: the files the viewer hands it in the Picker,
 * and nothing else in their Drive. */
const SCOPE = 'https://www.googleapis.com/auth/drive.file';

const app = express();

/**
 * Nothing this function answers may be cached, by anything, ever.
 *
 * Belt and braces, and the braces were missing: Hosting's own header rule
 * once matched `**`, which is every response it proxies -- so `GET
 * /session/{id}` was served from the edge for a minute. A television polled
 * once and the cache answered the rest; a collect made 46 milliseconds after
 * the handover was told the session was still waiting, and a pairing of
 * seventeen files was lost to a cache hit.
 *
 * Every route here is either a one-shot credential exchange or a question
 * whose answer changes by the second, so there is no response worth keeping
 * and none safe to keep. Said here as well as in `firebase.json` because
 * this one travels with the code.
 */
app.use((req, res, next) => {
  res.set('Cache-Control', 'no-store, max-age=0');
  next();
});
app.use(express.json());

/**
 * An async route whose failure is answered rather than left hanging.
 *
 * Express 4 does not look at the promise a handler returns, so a rejected
 * one -- Firestore unavailable, a fetch that could not connect, Google
 * answering a 5xx page that `json()` cannot parse -- reached nobody: no
 * response, and the television or the phone waited out the whole request
 * timeout for an answer that was never coming. This answers 502 instead.
 *
 * **Nothing of the failure goes out, and only its name goes in the log.**
 * A request here carries a refresh token or an auth code, and an error's
 * message can quote the request it failed on; the viewer's client needs to
 * know only that the service did not answer, which is what it already does
 * with any other 5xx.
 */
function answered(handler) {
  return (req, res, next) => {
    Promise.resolve(handler(req, res, next)).catch((error) => {
      console.error(`${req.method} ${req.route?.path}: ${error?.name || 'error'}`);
      if (res.headersSent) return;
      res.status(502).json({error: 'the service could not answer'});
    });
  };
}

/**
 * Where this service lives, as a viewer's phone sees it.
 *
 * Written down rather than read off the request. Behind a Hosting rewrite
 * the function is reached at its Cloud Run hostname
 * (`api-....a.run.app`), so `req.hostname` is not where the pages are
 * served, is not what the QR code should point at, and is not a redirect
 * URI the OAuth client knows -- the first `link` this returned sent a
 * phone to a host with nothing on it. This constant is the one the
 * console is configured with, and the exchange below has to present the
 * same one it authorised with or Google refuses the code.
 */
const PUBLIC_ORIGIN = 'https://xtremio-xervice.web.app';

function origin() {
  return PUBLIC_ORIGIN;
}

/**
 * The files out of one `POST /session/<id>/files` body, cleaned up: its
 * `{files: [...]}`, one entry per file the viewer chose.
 *
 * A row with no file id is dropped rather than refused: the id is the only
 * field a byte range is asked for, and the rest have answers for being
 * missing (`LinkedDriveFile.fromJson` in the app says the same). Every row
 * dropping is what the caller sees as an empty list.
 */
function pickedFiles(body) {
  const sent = Array.isArray(body.files) ? body.files : [];
  const files = [];
  for (const one of sent) {
    const fileId = typeof one?.fileId === 'string' ? one.fileId.trim() : '';
    if (!fileId) continue;
    files.push({
      fileId,
      name: typeof one.name === 'string' ? one.name : '',
      mimeType: typeof one.mimeType === 'string' ? one.mimeType : '',
    });
  }
  return files;
}

/**
 * What Drive says about one file: its name, and what it measured of the
 * video when it has measured it.
 *
 * **Measured at pairing time and not left for later.** The height is what
 * puts a Drive source in the right resolution section, and it is the one
 * thing about a linked file that cannot be read off its name. It used to
 * arrive on the first Reload, which is true and useless: nobody presses
 * Reload after linking, so every freshly linked file sat under "Unknown
 * resolution" until they happened to.
 *
 * `videoMediaMetadata` is absent more often than it is wrong -- Drive fills
 * it in once it has processed an upload, and never for a container it did
 * not understand -- so absent is the ordinary answer and not a failure.
 * `durationMillis` arrives as a **string**: it is an int64, and Google's
 * JSON mapping serialises those as strings, so a reader that took numbers
 * only would drop every duration and say nothing.
 */
async function describeFile(fileId, accessToken) {
  const read = await fetch(
      `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}` +
      '?fields=id,name,mimeType,videoMediaMetadata(width,height,durationMillis)',
      {headers: {Authorization: `Bearer ${accessToken}`}});
  if (!read.ok) return {ok: false, status: read.status};
  const file = await read.json();
  const measured = file.videoMediaMetadata || {};
  const height = Number(measured.height);
  const duration = Number(measured.durationMillis);
  return {
    ok: true,
    file: {
      fileId: file.id || fileId,
      name: typeof file.name === 'string' ? file.name : fileId,
      mimeType: typeof file.mimeType === 'string' ? file.mimeType : '',
      // Zero is nothing measured, not a zero-pixel video.
      height: Number.isFinite(height) && height > 0 ? height : null,
      durationMillis:
        Number.isFinite(duration) && duration > 0 ? duration : null,
    },
  };
}

/**
 * Refuses more than `limit` calls an hour for one key.
 *
 * Not a general rate limiter: one Firestore document per key, incremented,
 * reset when the hour rolls. It exists because this service is open by
 * design (see the note at the top) and an open endpoint that calls Google
 * on demand is somebody else's free service otherwise. A television asks
 * for a token about once an hour; sixty is room for every retry it could
 * reasonably make and far below what abuse looks like.
 */
async function withinRate(key, limit) {
  const hour = Math.floor(Date.now() / 3600000);
  const ref = db.collection('rate').doc(`${hour}-${key}`);
  const count = await db.runTransaction(async (tx) => {
    const seen = await tx.get(ref);
    const next = (seen.exists ? seen.data().n : 0) + 1;
    tx.set(ref, {n: next, expiresAt: new Date((hour + 2) * 3600000)});
    return next;
  });
  return count <= limit;
}

/**
 * The three shapes a pairing can be asked for by, and the only thing this
 * service is told about the device that asked.
 *
 * It decides two things, and they are not the same thing: whether the pick
 * page ends by sending the browser to [HAND_BACK_LINK] (`phone` alone), and
 * what that page says it has done (a `tv`'s viewer is looking at the other
 * screen; a `desktop`'s is looking at the page, and is told the pairing is
 * in the app and the window can be closed). While this was one boolean the
 * second question had no answer for a desktop, which was told its files were
 * on the way to a television it has not got.
 */
const SHAPES = ['tv', 'phone', 'desktop'];

/**
 * Which shape `POST /session` says it is, read strictly.
 *
 * Anything unrecognised is a television, which is the safe end of the two
 * decisions above: no hand-back is sent to a browser that may have nothing
 * to handle it, and the page says the least about a screen it cannot see.
 */
function shapeOf(body) {
  const asked = (body || {}).shape;
  return SHAPES.includes(asked) ? asked : 'tv';
}

/**
 * 1. The app asks for a session and gets something to draw.
 *
 * What it says about itself is its shape, and see [SHAPES] for what that is
 * for and why it is three words rather than a flag.
 */
app.post('/session', answered(async (req, res) => {
  const from = req.ip || 'unknown';
  if (!await withinRate(`session-${from}`, 60)) {
    return res.status(429).json({error: 'too many sessions'});
  }
  const id = crypto.randomUUID();
  const expiresAt = new Date(Date.now() + SESSION_MINUTES * 60000);
  await db.collection('sessions').doc(id).set({
    status: 'pending',
    shape: shapeOf(req.body),
    createdAt: FieldValue.serverTimestamp(),
    expiresAt,
  });
  res.json({
    sessionId: id,
    link: `${origin()}/link?s=${id}`,
    expiresAt: expiresAt.toISOString(),
  });
}));

/**
 * 4. Google sends the viewer back here with a code.
 *
 * `state` is the session id and is checked against a session that is still
 * pending: without that, anyone could hand this endpoint a code and have
 * the tokens written onto a session a television is watching.
 */
app.get('/oauth/callback', answered(async (req, res) => {
  const {code, state, error} = req.query;
  if (error) return res.redirect(`/pick?s=${state || ''}&error=${error}`);
  if (!code || !state) return res.status(400).send('missing code or state');

  const ref = db.collection('sessions').doc(String(state));
  const session = await ref.get();
  if (!session.exists || session.data().status !== 'pending') {
    return res.status(400).send('no session is waiting for this');
  }
  if (session.data().expiresAt.toDate() < new Date()) {
    return res.status(400).send('that code has expired');
  }

  const token = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams({
      code: String(code),
      client_id: CLIENT_ID.value(),
      client_secret: CLIENT_SECRET.value(),
      redirect_uri: `${origin()}/oauth/callback`,
      grant_type: 'authorization_code',
    }),
  });
  if (!token.ok) {
    return res.status(502).send(`google refused the code: ${token.status}`);
  }
  const granted = await token.json();
  // The refresh token is what the television will keep; the access token
  // is what the phone needs a moment from now to draw the Picker.
  await ref.update({
    status: 'signed-in',
    refreshToken: granted.refresh_token ?? null,
    accessToken: granted.access_token,
    accessExpiresAt: new Date(Date.now() + granted.expires_in * 1000),
  });
  res.redirect(`/pick?s=${state}`);
}));

/**
 * What the Picker page needs to draw itself: a token, where to send the
 * viewer afterwards, and what to call where the files went.
 *
 * `handBack` is the link or null rather than a flag, so that the URL the
 * page may navigate to is this file's constant and never a client's. `shape`
 * is the word the page words its confirmation from, and it is separate
 * because two of the three shapes are handed back nowhere and still have
 * different things said to them.
 */
app.get('/session/:id/token', answered(async (req, res) => {
  const session = await db.collection('sessions').doc(req.params.id).get();
  if (!session.exists) return res.status(404).json({error: 'no session'});
  const it = session.data();
  if (it.status !== 'signed-in') {
    return res.status(409).json({error: `session is ${it.status}`});
  }
  res.json({
    accessToken: it.accessToken,
    handBack: it.shape === 'phone' ? HAND_BACK_LINK : null,
    shape: SHAPES.includes(it.shape) ? it.shape : 'tv',
  });
}));

/**
 * 5. The phone says which files the viewer picked.
 *
 * One scan links as many files as the viewer chose in the one Picker, which
 * is what makes a season a single pairing rather than twelve.
 */
app.post('/session/:id/files', answered(async (req, res) => {
  const files = pickedFiles(req.body || {});
  if (files.length === 0) return res.status(400).json({error: 'no files'});
  if (files.length > MAX_FILES) {
    return res.status(400).json({error: `more than ${MAX_FILES} files`});
  }
  const ref = db.collection('sessions').doc(req.params.id);
  const session = await ref.get();
  if (!session.exists) return res.status(404).json({error: 'no session'});
  if (session.data().status !== 'signed-in') {
    return res.status(409).json({error: 'sign in first'});
  }
  // Measured here too, so that which path a pairing took is invisible
  // afterwards: the Picker sends a name and nothing else, and a file linked
  // from a browser would otherwise sit under "Unknown resolution" while the
  // same file linked from the app did not.
  //
  // Best effort, unlike the native path. There the read is also the proof
  // that the grant reached this client, so a failure is a pairing worth
  // refusing; here the sign-in already proved it and the names are in hand,
  // so a file Drive would not describe is linked with what the Picker said
  // rather than not linked at all.
  const accessToken = session.data().accessToken;
  const answers = await Promise.all(files.map((file) => accessToken
      ? describeFile(file.fileId, accessToken)
      : Promise.resolve({ok: false})));
  const described = answers.map((answer, at) => answer.ok
      ? answer.file
      : {...files[at], height: null, durationMillis: null});
  await ref.update({status: 'ready', files: described});
  res.json({ok: true, files: described.length});
}));

/**
 * 6. The television collects, once.
 *
 * The session is deleted in the same breath: a refresh token that has been
 * handed over is not something to leave lying in a database, and a pickup
 * that could happen twice is a pickup somebody else could make.
 */
app.get('/session/:id', answered(async (req, res) => {
  const ref = db.collection('sessions').doc(req.params.id);
  const session = await ref.get();
  if (!session.exists) return res.status(404).json({error: 'no session'});
  const it = session.data();
  if (it.expiresAt.toDate() < new Date()) {
    await ref.delete();
    return res.status(410).json({error: 'expired'});
  }
  if (it.status !== 'ready') return res.json({status: it.status});
  await ref.delete();
  res.json({
    status: 'ready',
    refreshToken: it.refreshToken,
    accessToken: it.accessToken,
    accessExpiresAt: it.accessExpiresAt.toDate().toISOString(),
    files: Array.isArray(it.files) ? it.files : [],
  });
}));

/**
 * 5b. A phone running *this app* says who signed in and what they picked, in
 * one call.
 *
 * The browser flow needs two ([oauth/callback] then `/session/:id/files`)
 * because a redirect carries the sign-in and a later fetch carries the
 * picking. A phone doing both natively has them at the same instant, so this
 * takes a session straight from `pending` to `ready`.
 *
 * **Why this exists at all.** The Google Picker cannot select more than one
 * file on a phone -- it gates selection on a Ctrl/Cmd key
 * (issuetracker.google.com/issues/334994030, open since 2024) -- while the
 * native Android picker can, measured at seven files in one go. So a phone
 * with this app installed picks natively and posts here; a phone without one
 * still gets the web page, which is why that page and `/session/:id/files`
 * stay exactly as they are.
 *
 * **The code is a *server* auth code**, issued for this web client because
 * the app asked for offline access naming it. That matters beyond the
 * exchange: a `drive.file` grant belongs to a user *and a client*, and the
 * television reads with this client's token -- so a pick recorded against
 * the Android client would grant the television nothing. Naming the web
 * client is what puts the grant where it can be used.
 *
 * **The picker returns ids and nothing else**, so the names are fetched here
 * rather than trusted from the phone: the television draws them, matches
 * them against Cinemeta and shows them to somebody, and a name is not a
 * thing a client should be able to make up about somebody else's Drive.
 */
app.post('/session/:id/android', answered(async (req, res) => {
  const {serverAuthCode} = req.body || {};
  const fileIds = (req.body || {}).fileIds;
  if (!serverAuthCode || typeof serverAuthCode !== 'string') {
    return res.status(400).json({error: 'no serverAuthCode'});
  }
  if (!Array.isArray(fileIds) || fileIds.length === 0) {
    return res.status(400).json({error: 'no fileIds'});
  }
  if (fileIds.length > MAX_FILES) {
    return res.status(400).json({error: `more than ${MAX_FILES} files`});
  }
  const ref = db.collection('sessions').doc(req.params.id);
  const session = await ref.get();
  if (!session.exists) return res.status(404).json({error: 'no session'});
  if (session.data().status !== 'pending') {
    return res.status(409).json({error: `session is ${session.data().status}`});
  }
  if (session.data().expiresAt.toDate() < new Date()) {
    return res.status(410).json({error: 'expired'});
  }

  // No `redirect_uri`: a server auth code from an installed app was not
  // issued against one, and sending a redirect the code never saw is what
  // `redirect_uri_mismatch` means.
  const token = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams({
      code: serverAuthCode,
      client_id: CLIENT_ID.value(),
      client_secret: CLIENT_SECRET.value(),
      grant_type: 'authorization_code',
    }),
  });
  const granted = await token.json();
  if (!token.ok) {
    return res.status(502).json({error: `google refused the code`,
      googleSaid: granted.error || null});
  }
  // A code minted without `forceCodeForRefreshToken` exchanges without one,
  // and a television cannot keep a session alive on an access token that
  // dies within the hour. Better a refusal here than a pairing that works
  // for fifty minutes.
  if (!granted.refresh_token) {
    return res.status(502).json({error: 'no refresh token in the exchange'});
  }

  // All at once, not one after another. A viewer is watching a spinner while
  // this happens, and a season of twelve episodes is twelve round trips to
  // Drive: in a row that is twelve latencies, together it is one. They are
  // independent reads of different files, so there is nothing to serialise
  // them for.
  const wanted = fileIds.filter((id) => typeof id === 'string' && id);
  const described = await Promise.all(
      wanted.map((id) => describeFile(id, granted.access_token)));
  const refused = described.findIndex((one) => !one.ok);
  if (refused !== -1) {
    // The one failure worth naming: the grant did not reach this client, so
    // the television would be handed ids it cannot open. Refuse the whole
    // pairing rather than write half of one.
    return res.status(502).json({
      error: 'the grant does not reach this client',
      fileId: wanted[refused],
      readStatus: described[refused].status,
    });
  }
  const files = described.map((one) => one.file);
  if (files.length === 0) return res.status(400).json({error: 'no fileIds'});

  await ref.update({
    status: 'ready',
    refreshToken: granted.refresh_token,
    accessToken: granted.access_token,
    accessExpiresAt: new Date(Date.now() + (granted.expires_in ?? 3600) * 1000),
    files,
  });
  res.json({ok: true, files: files.length});
}));

/**
 * 7. A fresh access token, later, for a film longer than one.
 *
 * This is the only reason the service outlives the pairing: an access
 * token is good for about an hour and a film is not, so the byte ranges
 * being read at minute sixty-one need a token nobody could mint without
 * the client secret.
 */
app.post('/refresh', answered(async (req, res) => {
  const refreshToken = (req.body || {}).refreshToken;
  if (!refreshToken) return res.status(400).json({error: 'no refreshToken'});
  const key = crypto.createHash('sha256').update(refreshToken).digest('hex')
      .slice(0, 32);
  if (!await withinRate(`refresh-${key}`, 60)) {
    return res.status(429).json({error: 'too many refreshes'});
  }
  const token = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams({
      refresh_token: refreshToken,
      client_id: CLIENT_ID.value(),
      client_secret: CLIENT_SECRET.value(),
      grant_type: 'refresh_token',
    }),
  });
  const granted = await token.json();
  if (!token.ok) {
    // Two answers mean this token will never refresh here again, and the
    // app's answer to both is to pair again, so say which:
    //
    //  * `invalid_grant` -- the viewer revoked us, or the consent screen is
    //    still in Testing, where refresh tokens die after seven days;
    //  * `unauthorized_client` -- the token was issued to another OAuth
    //    client. Every token from before the move to this project is one:
    //    without this, a television holding one was told Google could not
    //    be reached, forever, since the app only ever gives a credential up
    //    on `pairAgain`.
    //
    // Anything else -- `invalid_client` is *our* secret being wrong -- is
    // not the viewer's to fix and must not cost them their pairing.
    const pairAgain = ['invalid_grant', 'unauthorized_client']
        .includes(granted.error);
    // The error code only: the body can echo the request, token included.
    console.warn(`refresh refused: ${granted.error || token.status}`);
    return res.status(401).json({
      error: granted.error || 'refresh failed',
      pairAgain,
    });
  }
  res.json({
    accessToken: granted.access_token,
    expiresIn: granted.expires_in,
  });
}));

exports.api = onRequest(
    {secrets: [CLIENT_ID, CLIENT_SECRET], region: 'europe-west1'},
    app,
);

/**
 * "More like this", as its own function with its own secret (see
 * `similar.js`): a Gemini outage or a missing key cannot touch pairing, and
 * deploying pairing does not wait on a key this one needs.
 */
const {mountSimilar} = require('./similar');
const GEMINI_API_KEY = defineSecret('GEMINI_API_KEY');
const similarApp = express();
mountSimilar(similarApp, GEMINI_API_KEY);
exports.similar = onRequest(
    {secrets: [GEMINI_API_KEY], region: 'europe-west1', timeoutSeconds: 60},
    similarApp,
);
