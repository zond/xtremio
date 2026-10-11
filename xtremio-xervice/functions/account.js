/**
 * What xervice keeps for one Stremio account, and the proof that a request
 * is that account's.
 *
 * `POST /identity` with `{"authKey": "…"}` -- the session key a signed-in
 * Stremio client holds -- asks Stremio's own API who that key belongs to
 * (`POST https://api.strem.io/api/getUser`, the request stremio-core sends
 * as `APIRequest::GetUser`) and answers `{"token", "expiresAt"}`: a token
 * of this service's own, signed with [IDENTITY_KEY] and good for
 * [TOKEN_SECONDS], that names the account's stable user id and nothing
 * else. Every route that reads or writes what is kept for an account takes
 * that token as `Authorization: Bearer …`, and renewing it is the same call
 * again.
 *
 * **What is kept, and what is not.** The auth key passes through this
 * function once, to Stremio, and is not stored, not logged and not part
 * of the token. Neither is the e-mail address Stremio answers with: the
 * user id is the one field read out of the answer. The log names an
 * account by the first twelve hex of the id's SHA-256 at most.
 *
 * **Why a signed token and not a session document.** A token that carries
 * its own expiry and signature is checked with one HMAC and no read, and
 * there is nothing to clean up after it: no session collection, no TTL
 * policy, and nothing an attacker who could read Firestore would learn a
 * live credential from. The cost is that a token cannot be withdrawn
 * before it expires, which is why it lives an hour.
 *
 * **What is kept per account.** `faces/{user id}`: what the viewer said
 * about titles (`GET`/`PUT`/`DELETE /faces`), title ids and times in the
 * clear, merged newest-per-title so no device's first sync can drop what
 * another wrote.
 *
 * **Rate limits.** `/identity` calls Stremio on demand, so it is limited
 * per calling address the way the pairing routes are ([withinRate] in
 * `index.js`), and every route behind a token is limited per account.
 */

const crypto = require('crypto');

/** How long a token is good for. Renewal is the same call again. */
const TOKEN_SECONDS = 60 * 60;

/** `/identity` calls an hour from one address. A device renews about once
 * an hour of use; this is room for every retry and well short of using
 * this service to test stolen keys against Stremio. */
const IDENTITY_PER_HOUR = 30;

/** Calls an hour for one account to the routes behind a token. */
const ACCOUNT_PER_HOUR = 600;

const STREMIO_GET_USER = 'https://api.strem.io/api/getUser';

/** A Stremio user id is a Mongo ObjectId; this is generous about it while
 * keeping anything that is not a plain word out of a document path. */
const USER_ID = /^[A-Za-z0-9_-]{1,64}$/;

class Refusal extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

const b64url = (buffer) => Buffer.from(buffer).toString('base64url');

/** The first twelve hex of [id]'s SHA-256: enough to tell two accounts
 * apart in a log, and nothing a reader could look an account up by. */
function logName(id) {
  return crypto.createHash('sha256').update(String(id)).digest('hex')
      .slice(0, 12);
}

/** `v1.<payload>.<signature>`, the payload `{sub, exp}` (exp in ms). */
function signToken(key, sub, exp) {
  const payload = b64url(JSON.stringify({sub, exp}));
  const signature = crypto.createHmac('sha256', key)
      .update(`v1.${payload}`).digest();
  return `v1.${payload}.${b64url(signature)}`;
}

/**
 * The user id a token names, or null when it is not one this service
 * signed with [key], or it has expired by [now].
 */
function verifyToken(key, token, now) {
  if (typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 3 || parts[0] !== 'v1') return null;
  const expected = crypto.createHmac('sha256', key)
      .update(`v1.${parts[1]}`).digest();
  let given;
  try {
    given = Buffer.from(parts[2], 'base64url');
  } catch (_) {
    return null;
  }
  if (given.length !== expected.length ||
      !crypto.timingSafeEqual(given, expected)) {
    return null;
  }
  let payload;
  try {
    payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
  } catch (_) {
    return null;
  }
  if (!payload || typeof payload.sub !== 'string' ||
      !USER_ID.test(payload.sub) || typeof payload.exp !== 'number' ||
      payload.exp <= now) {
    return null;
  }
  return payload.sub;
}

/**
 * Where a request came from, as near as can be said behind Hosting.
 *
 * `req.ip` is the proxy in front of the function (no `trust proxy` is
 * set; see `POST /session` in `index.js`), so the first address of
 * `X-Forwarded-For`, which Hosting puts the caller's address first in, is
 * read instead. A caller can write that header itself; all it buys them is
 * a bucket of their own, and Stremio's own limits are behind this one.
 */
function addressOf(req) {
  const forwarded = req.headers?.['x-forwarded-for'];
  const first = typeof forwarded === 'string' ?
    forwarded.split(',')[0].trim() : '';
  return first || req.ip || 'unknown';
}

/**
 * Whether one more call under [key] is within [limit] this hour. One
 * Firestore document per key and hour, in the same `rate` collection and
 * with the same `expiresAt` TTL field as the pairing routes' limits.
 */
async function withinRate(deps, key, limit) {
  const hour = Math.floor(deps.now() / 3600000);
  const ref = deps.db.collection('rate').doc(`${hour}-${key}`);
  const count = await deps.db.runTransaction(async (tx) => {
    const seen = await tx.get(ref);
    const next = (seen.exists ? seen.data().n : 0) + 1;
    tx.set(ref, {n: next, expiresAt: new Date((hour + 2) * 3600000)});
    return next;
  });
  return count <= limit;
}

/**
 * Asks Stremio whose [authKey] this is: the user id, or a [Refusal] --
 * 401 for a key Stremio does not know, 502 for a Stremio that did not
 * answer. Nothing of the key or of Stremio's answer goes into a message.
 */
async function userIdFor(deps, authKey) {
  let response;
  try {
    response = await deps.fetch(STREMIO_GET_USER, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({type: 'GetUser', authKey}),
    });
  } catch (error) {
    throw new Refusal(502, `Stremio unreachable (${error?.name ?? 'error'})`);
  }
  if (response.status === 401 || response.status === 403) {
    throw new Refusal(401, 'not a Stremio session');
  }
  if (!response.ok) throw new Refusal(502, `Stremio answered ${response.status}`);
  let body;
  try {
    body = await response.json();
  } catch (_) {
    throw new Refusal(502, 'Stremio answer not understood');
  }
  const id = body?.result?._id;
  if (typeof id === 'string' && USER_ID.test(id)) return id;
  // `{"error": {"message", "code"}}` is how the API says no, with a 200.
  if (body?.error) throw new Refusal(401, 'not a Stremio session');
  throw new Refusal(502, 'Stremio answer not understood');
}

/** `POST /identity`. */
function identityHandler(keys, deps) {
  return async (req, res) => {
    res.set('Cache-Control', 'no-store, max-age=0');
    const d = deps();
    const authKey = req.body?.authKey;
    if (typeof authKey !== 'string' || !authKey || authKey.length > 512) {
      res.status(400).json({error: 'an authKey'});
      return;
    }
    try {
      const from = crypto.createHash('sha256').update(addressOf(req))
          .digest('hex').slice(0, 32);
      if (!await withinRate(d, `identity-${from}`, IDENTITY_PER_HOUR)) {
        res.status(429).json({error: 'too many identities'});
        return;
      }
      const sub = await userIdFor(d, authKey);
      const exp = d.now() + TOKEN_SECONDS * 1000;
      console.log(`identity: account ${logName(sub)}`);
      res.json({
        token: signToken(keys.identity.value(), sub, exp),
        expiresAt: new Date(exp).toISOString(),
      });
    } catch (error) {
      const status = error instanceof Refusal ? error.status : 502;
      // The message is this file's own words, never Stremio's or the key.
      console.warn(`identity refused: ${error instanceof Refusal ?
        error.message : error?.name ?? 'error'}`);
      res.status(status).json({error: status === 401 ?
        'not a Stremio session' : 'the service could not answer'});
    }
  };
}

/**
 * A handler that runs only for a request carrying a live token, with the
 * account's id as its third argument. A missing, forged or expired token
 * is 401, which is what tells the app to ask `/identity` again; an
 * account over its hourly calls is 429.
 */
function withAccount(keys, deps, handler) {
  return async (req, res) => {
    res.set('Cache-Control', 'no-store, max-age=0');
    const d = deps();
    const header = req.headers?.authorization;
    const bearer = typeof header === 'string' &&
      header.startsWith('Bearer ') ? header.slice(7).trim() : null;
    const sub = verifyToken(keys.identity.value(), bearer, d.now());
    if (!sub) {
      res.status(401).json({error: 'identity needed'});
      return;
    }
    try {
      if (!await withinRate(d, `account-${logName(sub)}`, ACCOUNT_PER_HOUR)) {
        res.status(429).json({error: 'too many requests'});
        return;
      }
      await handler(req, res, sub, d);
    } catch (error) {
      // The type only: a request here can carry a refresh token.
      console.error(`${req.method} ${req.path}: ${error?.name || 'error'}`);
      if (!res.headersSent) {
        res.status(502).json({error: 'the service could not answer'});
      }
    }
  };
}

/** The words a face can be stored as; `none` is one taken off again. */
const FACE_KINDS = ['like', 'dislike', 'dismissed', 'none'];

/** A title id as the app keys faces: Cinemeta's `tt…` and the other
 * addons' `prefix:id` shapes, and nothing that is not a plain token. */
const TITLE_ID = /^[A-Za-z0-9:_.-]{1,96}$/;

/** The most faces one account keeps: far past what anybody presses, and
 * a document a few hundred kilobytes at most. */
const FACES_LIMIT = 5000;

/**
 * `{faces: {id: {kind, at}}, clearedAt}` out of a stored document or a
 * sent body, every row this cannot read dropped. Null when [json] is not
 * that shape at all, which a sent body is refused for.
 */
function facesIn(json) {
  if (!json || typeof json !== 'object' || Array.isArray(json)) return null;
  const sent = json.faces;
  if (sent === undefined || sent === null) {
    return {faces: {}, clearedAt: clearedIn(json)};
  }
  if (typeof sent !== 'object' || Array.isArray(sent)) return null;
  const faces = {};
  for (const [id, mark] of Object.entries(sent)) {
    if (!TITLE_ID.test(id) || !mark || typeof mark !== 'object') continue;
    if (!FACE_KINDS.includes(mark.kind)) continue;
    if (!Number.isSafeInteger(mark.at) || mark.at < 0) continue;
    faces[id] = {kind: mark.kind, at: mark.at};
  }
  return {faces, clearedAt: clearedIn(json)};
}

function clearedIn(json) {
  const at = json?.clearedAt;
  return Number.isSafeInteger(at) && at > 0 ? at : 0;
}

/**
 * [stored] and [sent] together: per title the newer mark (the stored one
 * on a tie), and nothing at or before the stored `clearedAt` -- which only
 * `DELETE /faces` moves, so a device that has not heard of a "forget" yet
 * cannot bring back what it forgot. A mark only one side has is kept,
 * which is what makes a device's first sync add its set to the account's.
 */
function mergeFaces(stored, sent) {
  const clearedAt = stored.clearedAt;
  const faces = {};
  for (const source of [stored.faces, sent.faces]) {
    for (const [id, mark] of Object.entries(source)) {
      if (mark.at <= clearedAt) continue;
      if (!faces[id] || mark.at > faces[id].at) faces[id] = mark;
    }
  }
  return {faces, clearedAt};
}

/** `GET`, `PUT` and `DELETE /faces`, under [sub]'s own document. */
function facesRoutes(keys, deps) {
  const refOf = (d, sub) => d.db.collection('faces').doc(sub);
  return {
    get: withAccount(keys, deps, async (req, res, sub, d) => {
      const doc = await refOf(d, sub).get();
      res.json(facesIn(doc.exists ? doc.data() : {}));
    }),
    put: withAccount(keys, deps, async (req, res, sub, d) => {
      const sent = facesIn(req.body);
      if (!sent) {
        res.status(400).json({error: 'a set of faces'});
        return;
      }
      const ref = refOf(d, sub);
      const merged = await d.db.runTransaction(async (tx) => {
        const doc = await tx.get(ref);
        const next = mergeFaces(facesIn(doc.exists ? doc.data() : {}), sent);
        if (Object.keys(next.faces).length > FACES_LIMIT) return null;
        tx.set(ref, next);
        return next;
      });
      if (!merged) {
        res.status(413).json({error: `more than ${FACES_LIMIT} faces`});
        return;
      }
      res.json(merged);
    }),
    delete: withAccount(keys, deps, async (req, res, sub, d) => {
      const forgotten = {faces: {}, clearedAt: d.now()};
      await refOf(d, sub).set(forgotten);
      console.log(`faces forgotten: account ${logName(sub)}`);
      res.json(forgotten);
    }),
  };
}

/** The real dependencies, made when the first request needs them. */
function liveDeps() {
  const {getFirestore} = require('firebase-admin/firestore');
  return {db: getFirestore(), fetch, now: Date.now};
}

/**
 * Mounts the account routes on [app]. [keys] is `{identity}`, each a
 * secret with a `value()`.
 */
function mountAccount(app, keys, deps = liveDeps) {
  app.post('/identity', identityHandler(keys, deps));
  const faces = facesRoutes(keys, deps);
  app.get('/faces', faces.get);
  app.put('/faces', faces.put);
  app.delete('/faces', faces.delete);
}

module.exports = {
  mountAccount,
  identityHandler,
  withAccount,
  facesRoutes,
  mergeFaces,
  FACES_LIMIT,
  signToken,
  verifyToken,
  logName,
  TOKEN_SECONDS,
  IDENTITY_PER_HOUR,
  STREMIO_GET_USER,
};
