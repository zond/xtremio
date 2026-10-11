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
 * serves it at once -- the viewer never waits on a switch -- and then asks
 * the current model in the background, claiming the title first exactly
 * as a first ask does, and replaces the document when the answer lands. A
 * re-ask that fails leaves the stored answer where it was. At most
 * [REASK_CAP] re-asks a day are spent this way (a counter document per day
 * in `similarReasks`), so a switch costs a few days of trickle rather than
 * one day of every title at once; past the cap, the old answer is served
 * and nothing is asked. Switching the model is therefore: change [MODEL],
 * deploy, done.
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
 * Answers `{titles, model, stale, reask}`. `stale` is an answer from
 * another model than [MODEL]; `reask` says this request has claimed the
 * title for a background re-ask ([reask]) and is the one to run it.
 *
 * [deps] is `{db, fetch, now, sleep}`: Firestore, `fetch`, `Date.now` and
 * a delay, each a parameter so a test can stand in for it.
 */
async function answerFor(deps, key, type, id) {
  const {db, now} = deps;
  const ref = db.collection('similar').doc(`v${QUESTION_VERSION}_${type}_${id}`);
  const deadline = now() + WAIT_SECONDS * 1000;
  for (;;) {
    const claimed = await db.runTransaction(async (tx) => {
      const at = now();
      const day = new Date(at).toISOString().slice(0, 10);
      const capRef = db.collection('similarReasks').doc(day);
      // Every read before any write, as Firestore's transactions require.
      const doc = await tx.get(ref);
      const data = doc.exists ? doc.data() : null;
      if (data?.status === 'ready') {
        const answer = {titles: data.titles, model: data.model ?? null};
        if (data.model === MODEL) return {...answer, stale: false};
        // Another model's answer: served whatever happens next. Re-asked
        // only when nobody holds the title already and today's re-asks are
        // not spent.
        if (at - millisOf(data.reaskClaimedAt) < CLAIM_SECONDS * 1000) {
          return {...answer, stale: true};
        }
        const cap = await tx.get(capRef);
        const spent = cap.exists ? cap.data().n ?? 0 : 0;
        if (spent >= (deps.reaskCap ?? REASK_CAP)) {
          return {...answer, stale: true};
        }
        tx.set(capRef, {n: spent + 1});
        tx.set(ref, {...data, reaskClaimedAt: at});
        return {...answer, stale: true, reask: true};
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

/**
 * Asks [MODEL] about a title whose stored answer came from [was], and
 * replaces the document when it answers.
 *
 * A failure leaves the stored answer as it is, and leaves the claim too:
 * the title is tried again by the first read after [CLAIM_SECONDS], not by
 * every read in the meantime. Never throws.
 */
async function reask(deps, key, type, id, was) {
  const ref = deps.db.collection('similar')
      .doc(`v${QUESTION_VERSION}_${type}_${id}`);
  console.log(`similar ${type} ${id}: re-asking, ${was ?? 'no model'} -> ${MODEL}`);
  try {
    const titles = await askAbout(deps, key, type, id);
    await ref.set(answered(titles, deps.now()));
  } catch (error) {
    console.warn(`similar ${type} ${id}: re-ask failed: ${error.message}`);
  }
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
    res.json({titles: result.titles, version: QUESTION_VERSION,
      model: result.model});
    // After the answer has gone, and awaited rather than left floating: on
    // Cloud Run (functions v2) an instance's CPU is throttled once nothing
    // is still running for a request, so a promise left behind after the
    // handler returned could stall for minutes or never finish, holding
    // the claim for nothing. The viewer has the stored answer already;
    // only the request's server side stays open until the re-ask is done.
    if (result.reask) await reask(d, key.value(), type, id, result.model);
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
  titlesIn,
  question,
  QUESTION_VERSION,
  MODEL,
  REASK_CAP,
  CLAIM_SECONDS,
  CACHE_CURRENT,
  CACHE_STALE,
};
