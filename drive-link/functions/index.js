/**
 * Pairing a television with one Google Drive file, over a QR code.
 *
 * The television cannot run the Google Picker -- it is web-only -- and it
 * cannot hold the OAuth client secret, because it is an app anybody can
 * unpack. So the phone does the picking and this function does the two
 * things that need the secret: turning an authorization code into tokens,
 * and turning a refresh token into an access token.
 *
 * The flow, and what is stored at each step:
 *
 *   1. TV    POST /session            -> a session doc, `pending`, 10 min
 *   2. TV    shows a QR for /link?s=<id>
 *   3. phone signs in, redirected to  /oauth/callback?code&state=<id>
 *   4. here  exchanges the code, writes the refresh token on the session
 *   5. phone picks a file, POST /session/<id>/file, session becomes `ready`
 *   6. TV    GET /session/<id>        -> the tokens and the file, ONCE
 *   7. TV    POST /refresh            -> a fresh access token, later
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

/** What the app asks for, and the only thing it can ask for without a
 * Google security assessment: the files the viewer hands it in the Picker,
 * and nothing else in their Drive. */
const SCOPE = 'https://www.googleapis.com/auth/drive.file';

const app = express();
app.use(express.json());

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
const PUBLIC_ORIGIN = 'https://xtremio-drive.web.app';

function origin() {
  return PUBLIC_ORIGIN;
}

/** A short code a viewer could type if the camera will not read the QR. */
function humanCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no I/O/0/1
  return Array.from(crypto.randomFillSync(new Uint8Array(6)))
      .map((b) => alphabet[b % alphabet.length])
      .join('');
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

/** 1. The television asks for a session and gets something to draw. */
app.post('/session', async (req, res) => {
  const from = req.ip || 'unknown';
  if (!await withinRate(`session-${from}`, 60)) {
    return res.status(429).json({error: 'too many sessions'});
  }
  const id = crypto.randomUUID();
  const expiresAt = new Date(Date.now() + SESSION_MINUTES * 60000);
  await db.collection('sessions').doc(id).set({
    status: 'pending',
    code: humanCode(),
    createdAt: FieldValue.serverTimestamp(),
    expiresAt,
  });
  const session = await db.collection('sessions').doc(id).get();
  res.json({
    sessionId: id,
    code: session.data().code,
    link: `${origin()}/link?s=${id}`,
    expiresAt: expiresAt.toISOString(),
  });
});

/**
 * 4. Google sends the viewer back here with a code.
 *
 * `state` is the session id and is checked against a session that is still
 * pending: without that, anyone could hand this endpoint a code and have
 * the tokens written onto a session a television is watching.
 */
app.get('/oauth/callback', async (req, res) => {
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
});

/** What the Picker page needs to draw itself: a token, and nothing else. */
app.get('/session/:id/token', async (req, res) => {
  const session = await db.collection('sessions').doc(req.params.id).get();
  if (!session.exists) return res.status(404).json({error: 'no session'});
  const it = session.data();
  if (it.status !== 'signed-in') {
    return res.status(409).json({error: `session is ${it.status}`});
  }
  res.json({accessToken: it.accessToken});
});

/** 5. The phone says which file the viewer picked. */
app.post('/session/:id/file', async (req, res) => {
  const {fileId, name, mimeType} = req.body || {};
  if (!fileId) return res.status(400).json({error: 'no fileId'});
  const ref = db.collection('sessions').doc(req.params.id);
  const session = await ref.get();
  if (!session.exists) return res.status(404).json({error: 'no session'});
  if (session.data().status !== 'signed-in') {
    return res.status(409).json({error: 'sign in first'});
  }
  await ref.update({status: 'ready', file: {fileId, name, mimeType}});
  res.json({ok: true});
});

/**
 * 6. The television collects, once.
 *
 * The session is deleted in the same breath: a refresh token that has been
 * handed over is not something to leave lying in a database, and a pickup
 * that could happen twice is a pickup somebody else could make.
 */
app.get('/session/:id', async (req, res) => {
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
    file: it.file,
  });
});

/**
 * 7. A fresh access token, later, for a film longer than one.
 *
 * This is the only reason the service outlives the pairing: an access
 * token is good for about an hour and a film is not, so the byte ranges
 * being read at minute sixty-one need a token nobody could mint without
 * the client secret.
 */
app.post('/refresh', async (req, res) => {
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
    // `invalid_grant` is the viewer having revoked us, or the consent
    // screen still being in Testing, where refresh tokens die after seven
    // days. The app's answer to both is to pair again, so say which.
    return res.status(token.ok ? 200 : 401).json({
      error: granted.error || 'refresh failed',
      pairAgain: granted.error === 'invalid_grant',
    });
  }
  res.json({
    accessToken: granted.access_token,
    expiresIn: granted.expires_in,
  });
});

exports.api = onRequest(
    {secrets: [CLIENT_ID, CLIENT_SECRET], region: 'europe-west1'},
    app,
);
