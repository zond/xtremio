/**
 * A title's scores -- IMDb, TMDB, the Tomatometer and the Popcornmeter --
 * asked of MDBList once a week per title for everybody.
 *
 * `GET /ratings/{type}/{id}` -- a Cinemeta id (`tt…`) and `movie` or
 * `series` -- answers
 *
 *     {"imdb": {"score": 8.1, "votes": 673852},
 *      "tmdb": {"score": 7.6, "votes": 10114},
 *      "tomatoes": {"score": 97, "votes": 102},
 *      "popcorn": {"score": 90, "votes": 250000},
 *      "fetchedAt": "2026-10-03T12:00:00.000Z"}
 *
 * IMDb and TMDB are out of ten, the two Rotten Tomatoes meters are
 * percentages, `votes` is left out where MDBList states none, and a source
 * MDBList has no score for is `null`. `fetchedAt` is when MDBList was
 * asked, and `null` when it never answered for this title.
 *
 * **Why here and not in the app.** MDBList's key is the owner's, held in
 * Secret Manager (`MDBLIST_API_KEY`), and its free tier is a daily request
 * count: an answer fetched once here serves every install, where a key in
 * the app would be anybody's to spend.
 *
 * **Why it is safe to leave open.** The request names a type from a fixed
 * list and an id that must look like an IMDb id; the MDBList URL is built
 * here from those two and nothing else, so the endpoint cannot be pointed
 * anywhere. A title is fetched at most once per [FRESH_DAYS] (once per
 * [EMPTY_DAYS] when MDBList knew nothing about it), whatever asks.
 *
 * **What a failure costs, and what it does not.** MDBList answering 429
 * means the day's requests are spent; that is written down
 * ([LIMIT_DOC], until the reset MDBList names) and no title is fetched
 * again until then. Any other failure holds that one title back for
 * [RETRY_MINUTES]. In both cases the answer is what was stored before,
 * however old, or an answer with every score `null` -- never an error the
 * app must handle and never a retry. The key is never logged: it is in the
 * URL's query, so neither the URL nor a fetch error's text is.
 */

/** Our type words and MDBList's. */
const TYPES = {movie: 'movie', series: 'show'};
const ID = /^tt\d{1,12}$/;

const MDBLIST = 'https://api.mdblist.com/imdb';

/** How long a stored answer with scores in it is served before re-asking. */
const FRESH_DAYS = 7;

/**
 * How long an answer with no scores at all is served: a title MDBList
 * knows nothing about yet is often one released this week.
 */
const EMPTY_DAYS = 1;

/** How long a title waits after a failed fetch before it is tried again. */
const RETRY_MINUTES = 60;

/** How long a claim on a title keeps a second request from fetching too. */
const CLAIM_SECONDS = 30;

/** How long a request with nothing to serve waits on another's claim. */
const WAIT_SECONDS = 10;

/** How long the limit is assumed spent when MDBList names no reset. */
const LIMIT_FALLBACK_MINUTES = 60;

/** Where a spent daily limit is written down, in the `ratings` collection. */
const LIMIT_DOC = '_limit';

const DAY = 24 * 60 * 60 * 1000;
const SOURCES = ['imdb', 'tmdb', 'tomatoes', 'popcorn'];

class Refusal extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/** An answer with nothing in it. */
function emptyAnswer() {
  return {imdb: null, tmdb: null, tomatoes: null, popcorn: null};
}

/** A number MDBList gave, or null for anything else. */
function numberOr(value) {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

/**
 * The four scores in MDBList's answer, on the scales the app shows: IMDb
 * as MDBList's `value` (out of ten already), TMDB as its 0-100 `score`
 * out of ten, and the two meters as their percentage `score`.
 */
function scoresIn(body) {
  const answer = emptyAnswer();
  const ratings = Array.isArray(body?.ratings) ? body.ratings : [];
  for (const rating of ratings) {
    const source = rating?.source;
    if (!SOURCES.includes(source) || answer[source]) continue;
    const value = numberOr(rating.value);
    const score100 = numberOr(rating.score);
    let score;
    switch (source) {
      case 'imdb':
        score = value ?? (score100 == null ? null : score100 / 10);
        break;
      case 'tmdb':
        score = score100 == null ? value : score100 / 10;
        break;
      default:
        score = score100 ?? value;
    }
    if (score == null || score <= 0) continue;
    const out = {
      score: source === 'imdb' || source === 'tmdb' ?
        Math.round(score * 10) / 10 :
        Math.round(score),
    };
    const votes = numberOr(rating.votes);
    if (votes != null && votes > 0) out.votes = Math.round(votes);
    answer[source] = out;
  }
  return answer;
}

function hasScores(answer) {
  return SOURCES.some((source) => answer[source] != null);
}

/** When an answer fetched at [fetchedAt] (ms) wants fetching again. */
function staleAt(answer, fetchedAt) {
  return fetchedAt + (hasScores(answer) ? FRESH_DAYS : EMPTY_DAYS) * DAY;
}

/**
 * When MDBList says its limit resets: `X-RateLimit-Reset` (unix seconds),
 * else `Retry-After` (seconds from now), else [LIMIT_FALLBACK_MINUTES].
 */
function resetOf(response, now) {
  const reset = Number(response.headers?.get?.('x-ratelimit-reset'));
  if (Number.isFinite(reset) && reset * 1000 > now) return reset * 1000;
  const after = Number(response.headers?.get?.('retry-after'));
  if (Number.isFinite(after) && after > 0) return now + after * 1000;
  return now + LIMIT_FALLBACK_MINUTES * 60 * 1000;
}

/**
 * Asks MDBList about [id]. Answers the scores, or throws a [Refusal] whose
 * `limitUntil` is set when the day's requests are spent. A 404 is an
 * answer -- MDBList does not know the title -- not a failure.
 */
async function fetchScores(fetchImpl, key, type, id, now) {
  const url = `${MDBLIST}/${TYPES[type]}/${id}?apikey=${encodeURIComponent(key)}`;
  let response;
  try {
    response = await fetchImpl(url, {headers: {Accept: 'application/json'}});
  } catch (error) {
    // The error's name only: its message or cause can carry the URL.
    throw new Refusal(502, `MDBList unreachable (${error?.name ?? 'error'})`);
  }
  if (response.status === 429) {
    const refusal = new Refusal(502, 'MDBList daily limit spent');
    refusal.limitUntil = resetOf(response, now);
    throw refusal;
  }
  if (response.status === 404) return emptyAnswer();
  if (!response.ok) {
    // The status and nothing else: a body can quote the request back.
    throw new Refusal(502, `MDBList answered ${response.status}`);
  }
  let body;
  try {
    body = await response.json();
  } catch (_) {
    throw new Refusal(502, 'MDBList answer not understood');
  }
  return scoresIn(body);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * The scores for [type]/[id] and whether they are current: the stored
 * answer while it is fresh, a new one from MDBList when it is not and
 * nothing holds MDBList back, and otherwise the stored one however old,
 * or an empty one.
 *
 * Two requests for a title nobody has asked about yet pay for one fetch:
 * the first claims the title in a transaction and the second waits for
 * its answer. A request that finds a claim and has an old answer to hand
 * does not wait; it serves the old answer.
 *
 * [deps] is `{db, fetch, now, sleep}`: Firestore, `fetch`, `Date.now` and
 * a delay, each a parameter so a test can stand in for it.
 */
async function ratingsFor(deps, key, type, id) {
  const {db, now} = deps;
  const collection = db.collection('ratings');
  const ref = collection.doc(`${type}_${id}`);
  const limitRef = collection.doc(LIMIT_DOC);
  const deadline = now() + WAIT_SECONDS * 1000;
  let stored;
  for (;;) {
    const decision = await db.runTransaction(async (tx) => {
      const [doc, limit] = [await tx.get(ref), await tx.get(limitRef)];
      const data = doc.exists ? doc.data() : null;
      const known = data?.ratings ?
        {ratings: data.ratings, fetchedAt: data.fetchedAt} :
        null;
      const at = now();
      if (known && at < staleAt(known.ratings, known.fetchedAt)) {
        return {serve: known, fresh: true};
      }
      if ((data?.claimedAt ?? 0) + CLAIM_SECONDS * 1000 > at) {
        return known ? {serve: known} : {wait: true};
      }
      const held = Math.max(
          data?.retryAt ?? 0,
          limit.exists ? limit.data().until ?? 0 : 0,
      );
      if (held > at) return {serve: known};
      tx.set(ref, {...(data ?? {}), claimedAt: at});
      return {claimed: true, known};
    });
    if (decision.serve !== undefined) {
      return {answer: decision.serve, fresh: decision.fresh === true};
    }
    if (decision.claimed) {
      stored = decision.known;
      break;
    }
    if (now() > deadline) return {answer: null, fresh: false};
    await (deps.sleep ?? sleep)(1000);
  }
  try {
    const ratings = await fetchScores(deps.fetch, key, type, id, now());
    const fetchedAt = now();
    await ref.set({ratings, fetchedAt});
    return {answer: {ratings, fetchedAt}, fresh: true};
  } catch (error) {
    const at = now();
    if (error.limitUntil) {
      await limitRef.set({until: error.limitUntil}).catch(() => {});
    }
    // The claim goes, and the title is held back for a while whatever the
    // failure was: a broken answer asked for on every open would be a
    // retry storm with extra steps.
    await ref.set({
      ...(stored ?? {}),
      retryAt: at + RETRY_MINUTES * 60 * 1000,
    }).catch(() => {});
    console.warn(`ratings ${type} ${id}: ${error.message}`);
    return {answer: stored, fresh: false};
  }
}

/** The wire shape of a stored answer, or of none. */
function wire(answer) {
  if (!answer) return {...emptyAnswer(), fetchedAt: null};
  return {
    ...emptyAnswer(),
    ...answer.ratings,
    fetchedAt: new Date(answer.fetchedAt).toISOString(),
  };
}

/**
 * The route's handler, apart from Express so a test can call it with a
 * request and response of its own.
 */
function handler(key, deps) {
  return async (req, res) => {
    const {type, id} = req.params;
    if (!Object.hasOwn(TYPES, type) || !ID.test(id)) {
      res.status(400).json({error: 'a Cinemeta movie or series id'});
      return;
    }
    let result;
    try {
      result = await ratingsFor(deps(), key.value(), type, id);
    } catch (error) {
      // Firestore itself failed. Still an answer, and never kept.
      console.warn(`ratings ${type} ${id}: store failed (${error?.name})`);
      result = {answer: null, fresh: false};
    }
    // A current answer may sit at the edge for a day; one served because
    // MDBList could not be asked is kept a few minutes, so the edge
    // carries the load of a busy title without holding a stale answer
    // through the next day's limit.
    res.set(
        'Cache-Control',
        result.fresh ?
          'public, max-age=86400, s-maxage=86400' :
          'public, max-age=600, s-maxage=600',
    );
    res.json(wire(result.answer));
  };
}

/** The real dependencies, made when the first request needs them. */
function liveDeps() {
  const {getFirestore} = require('firebase-admin/firestore');
  return {db: getFirestore(), fetch, now: Date.now, sleep};
}

/** Mounts the route on [app]; [key] is the MDBList API key secret. */
function mountRatings(app, key, deps = liveDeps) {
  app.get('/ratings/:type/:id', handler(key, deps));
}

module.exports = {
  mountRatings,
  handler,
  ratingsFor,
  scoresIn,
  FRESH_DAYS,
  EMPTY_DAYS,
  RETRY_MINUTES,
  LIMIT_DOC,
};
