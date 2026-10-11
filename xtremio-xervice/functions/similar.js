/**
 * "More like this", asked once per title for everybody.
 *
 * `GET /similar/{type}/{id}` -- a Cinemeta id (`tt…`) and `movie` or
 * `series` -- answers `{"titles": [{title, year, kind, why}, …]}`: what a
 * model suggests watching after that title. The first answer for a title is
 * the answer, for every install: it is stored in Firestore under the title
 * and the version of the question, and every later request is a read.
 *
 * **Why here and not in the app.** A key each viewer pasted into Settings
 * would mean nobody but the owner ever has one, and an answer paid for on
 * one device is paid for again on the next. Here the key is the owner's,
 * held in Secret Manager, and a title costs one call however many devices
 * open it.
 *
 * **Why it is safe to leave open.** The request names a title by id and
 * nothing else. The question is built here, from the name and year
 * Cinemeta gives for that id, so nobody can put their own text through
 * the key; and each title is asked about once per question version, so the
 * most this can ever spend is one call per title in Cinemeta (about 200k,
 * well under $200 at Flash-Lite prices). The owner's Gemini budget cap is
 * the backstop past that.
 *
 * **There is no "ask again".** A re-ask anybody could send would re-bill
 * any title without end, and would replace the answer for everybody
 * because one viewer disliked it.
 *
 * **A model switch re-asks, slowly, by itself.** Every stored answer names
 * the [MODEL] that gave it. A read that finds another model's answer
 * serves it at once -- the viewer never waits on a switch -- and puts the
 * title on a queue (a `similarRevalidate` document per title), and that
 * is all the request does. The re-asking is [revalidatePass]'s, run by a
 * scheduled function every [REVALIDATE_MINUTES] minutes: it takes up to
 * [REVALIDATE_BATCH] queued titles, claims each exactly as a first ask
 * does, asks the current model and replaces the document when the answer
 * lands. Not after the response, because on Cloud Functions 2nd gen work
 * left running once a response is flushed runs with its CPU throttled and
 * can be stopped at any moment -- no place for a model call. A re-ask that
 * fails leaves the stored answer where it was and the title on the queue
 * for the next pass, [REVALIDATE_TRIES] times. At most [REASK_CAP] re-asks
 * a day are spent this way (a counter document per day in
 * `similarReasks`), so a switch costs a few days of trickle rather than
 * one day of every title at once; past the cap, the queue waits for the
 * next day. Switching the model is therefore: change [MODEL], deploy,
 * done.
 *
 * The question's wording is measured in `tool/recommendations/`. Changing
 * it means a new [QUESTION_VERSION], which is what makes every title be
 * asked again at once -- the old answers are to another question and are
 * not served while the new ones arrive.
 */

/**
 * Bump when the question or the schema changes -- not for a new model,
 * which re-asks by itself (see the header).
 */
const QUESTION_VERSION = 1;

const MODEL = 'gemini-3.1-flash-lite';
const GEMINI =
  `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`;
const CINEMETA = 'https://v3-cinemeta.strem.io/meta';
const COUNT = 10;

/**
 * The most background re-asks for a model switch in one UTC day. Two
 * thousand Flash-Lite calls are well under a dollar; the most-opened titles
 * are the ones read first, so they are the ones re-asked first.
 */
const REASK_CAP = 2000;

/**
 * How often the queue is worked ([revalidatePass], `exports.similarRevalidate`
 * in `index.js`), and how many titles a pass takes. 144 passes of 14 is
 * 2016 a day, so the batch alone almost keeps [REASK_CAP]; the counter is
 * what holds it exactly.
 */
const REVALIDATE_MINUTES = 10;
const REVALIDATE_BATCH = 14;

/** How many passes a title that keeps failing stays queued for. */
const REVALIDATE_TRIES = 3;

/** How long a claim on a title keeps a second request from asking too. */
const CLAIM_SECONDS = 60;

/** How long a request waits for another's claim to turn into an answer. */
const WAIT_SECONDS = 20;

const TYPES = {movie: 'film', series: 'series'};
const ID = /^tt\d{1,12}$/;

const SYSTEM =
  'You recommend films and television. Real, released titles only. ' +
  'JSON only.';

const ANSWER_SHAPE =
  'Answer JSON only: {"titles":[{"title":"","year":0,' +
  '"kind":"film|series","why":"under 12 words"}]}.';

/** The question, unchanged from what `tool/recommendations/` measured. */
function question(subject, about) {
  if (about === 'series') {
    return `Name ${COUNT} television series or films to watch next for ` +
      `someone who loved ${subject}. ` +
      'Prefer series that *feel* like it -- the same register, pace and ' +
      'texture -- over series that merely share its premise; a film that ' +
      'genuinely fits belongs in the answer too. ' +
      `${ANSWER_SHAPE} ` +
      'Real, released titles only; do not include the series itself.';
  }
  return `Name ${COUNT} films or television series to watch next for ` +
    `someone who loved ${subject}. ` +
    'Prefer films that *feel* like it -- the same register, pace and ' +
    'texture -- over films that merely share its premise. ' +
    `${ANSWER_SHAPE} ` +
    'Real, released titles only; do not include the film itself.';
}

function body(subject, about) {
  return {
    system_instruction: {parts: [{text: SYSTEM}]},
    contents: [{parts: [{text: question(subject, about)}]}],
    // No sampling parameters: Gemini ignores them since 3.6 Flash and will
    // refuse requests that carry them (Google's notice of 2026-10), so the
    // model's own defaults apply. Not a change of the question or the
    // model, so QUESTION_VERSION stays and the stored answers stand.
    generationConfig: {
      responseMimeType: 'application/json',
      responseSchema: {
        type: 'OBJECT',
        properties: {
          titles: {
            type: 'ARRAY',
            items: {
              type: 'OBJECT',
              properties: {
                title: {type: 'STRING'},
                year: {type: 'INTEGER'},
                kind: {type: 'STRING'},
                why: {type: 'STRING'},
              },
              required: ['title', 'year', 'kind', 'why'],
            },
          },
        },
        required: ['titles'],
      },
    },
  };
}

class Refusal extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/** `Avalon (2001)`: the name Cinemeta has for [id], and its year. */
async function subjectOf(fetchImpl, type, id) {
  const response = await fetchImpl(`${CINEMETA}/${type}/${id}.json`);
  if (!response.ok) throw new Refusal(502, 'catalogue unreachable');
  const meta = (await response.json()).meta;
  if (!meta || typeof meta.name !== 'string' || !meta.name.trim()) {
    throw new Refusal(404, 'no such title');
  }
  const year = /\d{4}/.exec(String(meta.releaseInfo ?? meta.year ?? ''));
  return year ? `${meta.name} (${year[0]})` : meta.name;
}

/** Only the fields the app reads, and only well-formed ones. */
function titlesIn(answer) {
  const text = answer?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (typeof text !== 'string') throw new Refusal(502, 'no answer');
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (_) {
    throw new Refusal(502, 'answer not understood');
  }
  const titles = Array.isArray(parsed?.titles) ? parsed.titles : [];
  return titles
      .filter((t) => t && typeof t.title === 'string' && t.title.trim())
      .slice(0, COUNT)
      .map((t) => ({
        title: t.title.trim(),
        year: Number.isInteger(t.year) ? t.year : null,
        kind: typeof t.kind === 'string' ? t.kind : null,
        why: typeof t.why === 'string' ? t.why : null,
      }));
}

async function ask(fetchImpl, key, subject, about) {
  let response;
  try {
    response = await fetchImpl(GEMINI, {
      method: 'POST',
      headers: {'Content-Type': 'application/json', 'x-goog-api-key': key},
      body: JSON.stringify(body(subject, about)),
    });
  } catch (error) {
    // The error's name only: its message or cause can carry the request.
    throw new Refusal(502, `model unreachable (${error?.name ?? 'error'})`);
  }
  if (!response.ok) {
    // The status and nothing else: a body can quote the request back.
    throw new Refusal(502, `model answered ${response.status}`);
  }
  return titlesIn(await response.json());
}

/** The model's answer about [type]/[id]: Cinemeta's name, then the model. */
async function askAbout(deps, key, type, id) {
  return ask(deps.fetch, key, await subjectOf(deps.fetch, type, id), TYPES[type]);
}

/** The document an answer is written as. */
function answered(titles, now) {
  return {
    status: 'ready',
    titles,
    model: MODEL,
    version: QUESTION_VERSION,
    answeredAt: new Date(now),
  };
}

/** A stored instant in milliseconds: a Firestore Timestamp, a number, or 0. */
function millisOf(value) {
  if (typeof value === 'number') return value;
  return value?.toMillis?.() ?? 0;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * The stored answer for [type]/[id], asking the model first when there is
 * none. A title being asked about by another request right now is waited
 * for rather than asked again: two devices opening a new title at once pay
 * for one call.
 *
 * Answers `{titles, model, stale}`. `stale` is an answer from another
 * model than [MODEL], which this read has put on the re-ask queue unless
 * it was already there.
 *
 * [deps] is `{db, fetch, now, sleep}`: Firestore, `fetch`, `Date.now` and
 * a delay, each a parameter so a test can stand in for it.
 */
async function answerFor(deps, key, type, id) {
  const {db, now} = deps;
  const ref = db.collection('similar').doc(docId(type, id));
  const deadline = now() + WAIT_SECONDS * 1000;
  for (;;) {
    const claimed = await db.runTransaction(async (tx) => {
      const at = now();
      const queued = db.collection('similarRevalidate').doc(docId(type, id));
      // Every read before any write, as Firestore's transactions require.
      const doc = await tx.get(ref);
      const data = doc.exists ? doc.data() : null;
      if (data?.status === 'ready') {
        const answer = {titles: data.titles, model: data.model ?? null};
        if (data.model === MODEL) return {...answer, stale: false};
        // Another model's answer: served, and queued for the scheduled
        // pass once -- a read of a title already queued writes nothing.
        const mark = await tx.get(queued);
        if (!mark.exists) tx.set(queued, {type, id, markedAt: at, tries: 0});
        return {...answer, stale: true};
      }
      if (data?.status === 'pending' &&
          at - millisOf(data.claimedAt) < CLAIM_SECONDS * 1000) {
        return {wait: true};
      }
      tx.set(ref, {status: 'pending', claimedAt: at});
      return {claimed: true};
    });
    if (claimed.titles) return claimed;
    if (claimed.claimed) break;
    if (now() > deadline) throw new Refusal(503, 'still being asked');
    await (deps.sleep ?? sleep)(1000);
  }
  try {
    const titles = await askAbout(deps, key, type, id);
    await ref.set(answered(titles, now()));
    return {titles, model: MODEL, stale: false};
  } catch (error) {
    // Let the next request try: a claim left behind would hold the title
    // for a minute for nothing.
    await ref.delete().catch(() => {});
    throw error;
  }
}

/** The document a title's answer is kept in, and its queue entry's id. */
function docId(type, id) {
  return `v${QUESTION_VERSION}_${type}_${id}`;
}

/**
 * One pass over the re-ask queue: up to [REVALIDATE_BATCH] queued titles,
 * oldest first, and never past today's [REASK_CAP]. Each is claimed in a
 * transaction that counts it against the cap -- a title already answered
 * by [MODEL] by then, or gone, just leaves the queue -- then asked, its
 * document replaced, and its queue entry removed. A failure keeps the
 * stored answer and the entry, until it has failed [REVALIDATE_TRIES]
 * times. One log line per re-ask, naming the title and both models.
 * Answers how many were re-asked. Never throws for one title.
 */
async function revalidatePass(deps, key, batch = REVALIDATE_BATCH) {
  const {db, now} = deps;
  const cap = deps.reaskCap ?? REASK_CAP;
  const queue = db.collection('similarRevalidate');
  const day = new Date(now()).toISOString().slice(0, 10);
  const capRef = db.collection('similarReasks').doc(day);
  const capDoc = await capRef.get();
  const left = cap - (capDoc.exists ? capDoc.data().n ?? 0 : 0);
  if (left <= 0) return 0;
  const listed = await queue.orderBy('markedAt').limit(Math.min(batch, left))
      .get();
  let asked = 0;
  for (const entry of listed.docs) {
    const {type, id, tries = 0} = entry.data();
    const markRef = queue.doc(entry.id);
    if (!Object.hasOwn(TYPES, type) || !ID.test(id)) {
      await markRef.delete();
      continue;
    }
    const ref = db.collection('similar').doc(docId(type, id));
    const claim = await db.runTransaction(async (tx) => {
      const at = now();
      const [doc, spent] = [await tx.get(ref), await tx.get(capRef)];
      const data = doc.exists ? doc.data() : null;
      if (data?.status !== 'ready' || data.model === MODEL) {
        return {done: true};
      }
      if (at - millisOf(data.reaskClaimedAt) < CLAIM_SECONDS * 1000) {
        return {held: true};
      }
      const n = spent.exists ? spent.data().n ?? 0 : 0;
      if (n >= cap) return {spent: true};
      tx.set(capRef, {n: n + 1});
      tx.set(ref, {...data, reaskClaimedAt: at});
      return {was: data.model ?? null};
    });
    if (claim.spent) break;
    if (claim.held) continue;
    if (claim.done) {
      await markRef.delete();
      continue;
    }
    asked++;
    console.log(`similar ${type} ${id}: re-asking, ${claim.was ?? 'no model'} -> ${MODEL}`);
    try {
      const titles = await askAbout(deps, key, type, id);
      await ref.set(answered(titles, now()));
      await markRef.delete();
    } catch (error) {
      console.warn(`similar ${type} ${id}: re-ask failed: ${error.message}`);
      if (tries + 1 >= REVALIDATE_TRIES) {
        await markRef.delete();
      } else {
        await markRef.set({...entry.data(), tries: tries + 1});
      }
    }
  }
  return asked;
}

/**
 * What the edge may keep, and for how long.
 *
 * A current answer changes only when the model or the question does, so
 * the edge keeps it a day and then, for a week more, serves it at once
 * while it fetches the next copy behind the viewer's back
 * (`stale-while-revalidate`): a title is never slow at the edge, and a
 * model switch reaches it within a day of the document being replaced. A
 * day rather than the week this used to be, because that day is how long
 * a replaced answer waits behind the old one.
 *
 * Another model's answer is about to be replaced, so the edge holds it ten
 * minutes -- long enough to carry a busy title, short enough that the new
 * answer is picked up soon after it lands -- and revalidates in the
 * background for a day after that.
 */
const CACHE_CURRENT =
  'public, max-age=86400, s-maxage=86400, stale-while-revalidate=604800';
const CACHE_STALE =
  'public, max-age=600, s-maxage=600, stale-while-revalidate=86400';

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
    const d = deps();
    let result;
    try {
      result = await answerFor(d, key.value(), type, id);
    } catch (error) {
      const status = error instanceof Refusal ? error.status : 500;
      // Never kept at the edge: a failure is not the answer.
      res.set('Cache-Control', 'no-store, max-age=0');
      console.warn(`similar ${type} ${id}: ${error.message}`);
      res.status(status).json({error: error.message});
      return;
    }
    res.set('Cache-Control', result.stale ? CACHE_STALE : CACHE_CURRENT);
    // Nothing runs after this: a stale answer was queued, not re-asked
    // (see the header).
    res.json({titles: result.titles, version: QUESTION_VERSION,
      model: result.model});
  };
}

/** The real dependencies, made when the first request needs them. */
function liveDeps() {
  const {getFirestore} = require('firebase-admin/firestore');
  return {db: getFirestore(), fetch, now: Date.now, sleep};
}

/** Mounts the route on [app]; [key] is the Gemini API key secret. */
function mountSimilar(app, key, deps = liveDeps) {
  app.get('/similar/:type/:id', handler(key, deps));
}

module.exports = {
  mountSimilar,
  handler,
  answerFor,
  revalidatePass,
  liveDeps,
  titlesIn,
  question,
  QUESTION_VERSION,
  MODEL,
  REASK_CAP,
  CLAIM_SECONDS,
  REVALIDATE_MINUTES,
  REVALIDATE_BATCH,
  REVALIDATE_TRIES,
  CACHE_CURRENT,
  CACHE_STALE,
};
