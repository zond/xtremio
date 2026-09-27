/**
 * "More like this", asked once per title for everybody.
 *
 * `GET /similar/{type}/{id}` -- a Cinemeta id (`tt…`) and `movie` or
 * `series` -- answers `{"titles": [{title, year, kind, why}, …]}`: what a
 * model suggests watching after that title. The first answer for a title is
 * the answer, for every install: it is stored in Firestore under the title
 * and the version of the question, and every later request is a read.
 *
 * **Why here and not in the app.** The app used to ask Gemini itself, with
 * a key each viewer pasted into Settings. Nobody but the owner ever had
 * one, and an answer paid for on one device was paid for again on the
 * next. Here the key is the owner's, held in Secret Manager, and a title
 * costs one call however many devices open it.
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
 * The question is the one the app asked (`lib/features/similar/
 * similar_titles.dart` before this moved), measured in
 * `tool/recommendations/`. Changing its wording means a new
 * [QUESTION_VERSION], which is also what makes every title be asked again.
 */

const {getFirestore, FieldValue} = require('firebase-admin/firestore');

/** Bump when the question, the schema or the model changes. */
const QUESTION_VERSION = 1;

const MODEL = 'gemini-3.1-flash-lite';
const GEMINI =
  `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`;
const CINEMETA = 'https://v3-cinemeta.strem.io/meta';
const COUNT = 10;

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

/** The question the app used to ask itself, kept word for word: `tool/recommendations/` measured this wording. */
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
    generationConfig: {
      temperature: 0.7,
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
async function subjectOf(type, id) {
  const response = await fetch(`${CINEMETA}/${type}/${id}.json`);
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

async function ask(key, subject, about) {
  const response = await fetch(GEMINI, {
    method: 'POST',
    headers: {'Content-Type': 'application/json', 'x-goog-api-key': key},
    body: JSON.stringify(body(subject, about)),
  });
  if (!response.ok) {
    // The status and nothing else: a body can quote the request back.
    throw new Refusal(502, `model answered ${response.status}`);
  }
  return titlesIn(await response.json());
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * The stored answer for [type]/[id], asking the model first when there is
 * none. A title being asked about by another request right now is waited
 * for rather than asked again: two devices opening a new title at once pay
 * for one call.
 */
async function answerFor(key, type, id) {
  const db = getFirestore();
  const ref = db.collection('similar').doc(`v${QUESTION_VERSION}_${type}_${id}`);
  const deadline = Date.now() + WAIT_SECONDS * 1000;
  for (;;) {
    const claimed = await db.runTransaction(async (tx) => {
      const doc = await tx.get(ref);
      const data = doc.exists ? doc.data() : null;
      if (data?.status === 'ready') return {ready: data.titles};
      const claimedAt = data?.claimedAt?.toMillis?.() ?? 0;
      if (data?.status === 'pending' &&
          Date.now() - claimedAt < CLAIM_SECONDS * 1000) {
        return {wait: true};
      }
      tx.set(ref, {status: 'pending', claimedAt: FieldValue.serverTimestamp()});
      return {claimed: true};
    });
    if (claimed.ready) return claimed.ready;
    if (claimed.claimed) break;
    if (Date.now() > deadline) throw new Refusal(503, 'still being asked');
    await sleep(1000);
  }
  try {
    const titles = await ask(key, await subjectOf(type, id), TYPES[type]);
    await ref.set({
      status: 'ready',
      titles,
      model: MODEL,
      version: QUESTION_VERSION,
      answeredAt: FieldValue.serverTimestamp(),
    });
    return titles;
  } catch (error) {
    // Let the next request try: a claim left behind would hold the title
    // for a minute for nothing.
    await ref.delete().catch(() => {});
    throw error;
  }
}

/** Mounts the route on [app]; [key] is the Gemini API key secret. */
function mountSimilar(app, key) {
  app.get('/similar/:type/:id', async (req, res) => {
    const {type, id} = req.params;
    if (!Object.hasOwn(TYPES, type) || !ID.test(id)) {
      res.status(400).json({error: 'a Cinemeta movie or series id'});
      return;
    }
    try {
      const titles = await answerFor(key.value(), type, id);
      // An answer never changes for a question version, so the edge may
      // keep it: a repeat request is then not even a Firestore read.
      res.set('Cache-Control', 'public, max-age=86400, s-maxage=604800');
      res.json({titles, version: QUESTION_VERSION});
    } catch (error) {
      const status = error instanceof Refusal ? error.status : 500;
      // Never kept at the edge: a failure is not the answer.
      res.set('Cache-Control', 'no-store, max-age=0');
      console.warn(`similar ${type} ${id}: ${error.message}`);
      res.status(status).json({error: error.message});
    }
  });
}

module.exports = {mountSimilar, titlesIn, question, QUESTION_VERSION};
