// `node --test` from functions/: the similar route against a Firestore, a
// Cinemeta and a Gemini that live in this file. Nothing here needs
// node_modules.

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  handler,
  revalidatePass,
  REVALIDATE_BATCH,
  REVALIDATE_TRIES,
  QUESTION_VERSION,
  MODEL,
  REASK_CAP,
  CLAIM_SECONDS,
  CACHE_CURRENT,
  CACHE_STALE,
} = require('../similar');

const KEY = 'the-gemini-key';
const ID = 'tt0267287';
const DOC = `similar/v${QUESTION_VERSION}_movie_${ID}`;
const START = Date.UTC(2026, 9, 11, 12);

/** The part of Firestore the route uses, kept in a Map; optimistic
 * transactions as Firestore's are. */
function fakeDb() {
  const docs = new Map();
  const versions = new Map();
  const write = (path, data) => {
    docs.set(path, structuredClone(data));
    versions.set(path, (versions.get(path) ?? 0) + 1);
  };
  const snapshot = (path) => ({
    exists: docs.has(path),
    data: () => structuredClone(docs.get(path)),
  });
  const ref = (path) => ({
    path,
    id: path.slice(path.indexOf('/') + 1),
    async get() {
      return snapshot(path);
    },
    async set(data) {
      write(path, data);
    },
    async delete() {
      docs.delete(path);
      versions.set(path, (versions.get(path) ?? 0) + 1);
    },
  });
  return {
    docs,
    collection: (name) => ({
      doc: (id) => ref(`${name}/${id}`),
      // `orderBy(field).limit(n).get()`, which is all the pass asks.
      orderBy: (field) => ({
        limit: (n) => ({
          async get() {
            const rows = [...docs.keys()]
                .filter((path) => path.startsWith(`${name}/`))
                .map((path) => ({id: path.slice(name.length + 1),
                  data: () => structuredClone(docs.get(path))}))
                .sort((a, b) => a.data()[field] - b.data()[field]);
            return {docs: rows.slice(0, n)};
          },
        }),
      }),
    }),
    async runTransaction(fn) {
      for (;;) {
        const read = new Map();
        const writes = [];
        const result = await fn({
          get: async (r) => {
            read.set(r.path, versions.get(r.path) ?? 0);
            await null;
            return snapshot(r.path);
          },
          set: (r, data) => writes.push([r.path, data]),
        });
        if ([...read].every(([path, v]) => (versions.get(path) ?? 0) === v)) {
          for (const [path, data] of writes) write(path, data);
          return result;
        }
      }
    },
  };
}

function response(status, body) {
  return {status, ok: status >= 200 && status < 300, json: async () => body};
}

/** A Gemini answer naming [titles]. */
function gemini(...titles) {
  return response(200, {candidates: [{content: {parts: [{text: JSON.stringify({
    titles: titles.map((title) => ({title, year: 1999, kind: 'film',
      why: 'alike'})),
  })}]}}]});
}

const AVALON = response(200, {meta: {name: 'Avalon', releaseInfo: '2001'}});

/** Deps over [db]; Cinemeta always answers, Gemini answers [answers] in
 * turn. `asked` counts the calls to Gemini. */
function deps(db, answers) {
  const clock = {t: START};
  const d = {
    db,
    clock,
    asked: 0,
    now: () => clock.t,
    sleep: async (ms) => {
      clock.t += ms;
    },
    fetch: async (url) => {
      if (url.startsWith('https://v3-cinemeta.strem.io/')) return AVALON;
      d.asked++;
      const next = answers.shift();
      if (next instanceof Error) throw next;
      return next;
    },
  };
  return d;
}

function fakeRes() {
  return {
    statusCode: 200,
    headers: {},
    body: undefined,
    status(code) {
      this.statusCode = code;
      return this;
    },
    set(name, value) {
      this.headers[name] = value;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };
}

/** One request; resolves when the handler is done, background work and
 * all. `res.body` is what the viewer got. */
async function get(d, id = ID) {
  const res = fakeRes();
  await handler({value: () => KEY}, () => d)({params: {type: 'movie', id}}, res);
  return res;
}

/** A document answered by another model. */
function storeOld(db) {
  db.docs.set(DOC, {
    status: 'ready',
    titles: [{title: 'Old', year: 1990, kind: 'film', why: 'old'}],
    model: 'gemini-old',
    version: QUESTION_VERSION,
    answeredAt: new Date(START - 1000),
  });
}

function quietly(fn) {
  return async () => {
    const [log, warn] = [console.log, console.warn];
    console.log = () => {};
    console.warn = () => {};
    try {
      await fn();
    } finally {
      console.log = log;
      console.warn = warn;
    }
  };
}

test('a first ask is stored with the model and answered with it', async () => {
  const db = fakeDb();
  const d = deps(db, [gemini('Ghost in the Shell')]);
  const res = await get(d);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body.titles.map((t) => t.title), ['Ghost in the Shell']);
  assert.equal(res.body.model, MODEL);
  assert.equal(res.body.version, QUESTION_VERSION);
  assert.equal(res.headers['Cache-Control'], CACHE_CURRENT);
  assert.match(CACHE_CURRENT, /stale-while-revalidate=/);
  assert.equal(db.docs.get(DOC).model, MODEL);
  assert.equal(d.asked, 1);
});

test('the same model is served and nothing is asked', async () => {
  const db = fakeDb();
  const d = deps(db, [gemini('Ghost in the Shell')]);
  await get(d);
  const again = await get(d);
  assert.deepEqual(again.body.titles.map((t) => t.title), ['Ghost in the Shell']);
  assert.equal(again.headers['Cache-Control'], CACHE_CURRENT);
  assert.equal(d.asked, 1);
  assert.equal(db.docs.has('similarReasks/2026-10-11'), false);
});

const QUEUE = `similarRevalidate/v${QUESTION_VERSION}_movie_${ID}`;

/** A title answered by another model, under [id]. */
function storeOldAt(db, id) {
  db.docs.set(`similar/v${QUESTION_VERSION}_movie_${id}`, {
    status: 'ready',
    titles: [{title: 'Old', year: 1990, kind: 'film', why: 'old'}],
    model: 'gemini-old',
    version: QUESTION_VERSION,
    answeredAt: new Date(START - 1000),
  });
}

test('a stale read is served at once, queued once, and asks nothing',
    async () => {
      const db = fakeDb();
      storeOld(db);
      const d = deps(db, [gemini('New')]);
      const res = await get(d);
      assert.deepEqual(res.body.titles.map((t) => t.title), ['Old']);
      assert.equal(res.body.model, 'gemini-old');
      assert.equal(res.headers['Cache-Control'], CACHE_STALE);
      assert.equal(d.asked, 0, 'no model call in the request');
      assert.deepEqual(db.docs.get(QUEUE),
          {type: 'movie', id: ID, markedAt: START, tries: 0});

      d.clock.t += 5000;
      await get(d);
      assert.equal(db.docs.get(QUEUE).markedAt, START, 'queued once');
      assert.equal(d.asked, 0);
      assert.equal(db.docs.get(DOC).model, 'gemini-old');
    });

test('the scheduled pass re-asks queued titles, replaces them, empties the '
    + 'queue, and logs one line each', async () => {
  const db = fakeDb();
  storeOld(db);
  const d = deps(db, [gemini('New')]);
  await get(d);
  const lines = [];
  const log = console.log;
  console.log = (...args) => lines.push(args.join(' '));
  try {
    assert.equal(await revalidatePass(d, KEY), 1);
  } finally {
    console.log = log;
  }
  assert.equal(d.asked, 1);
  assert.equal(db.docs.get(DOC).model, MODEL);
  assert.deepEqual(db.docs.get(DOC).titles.map((t) => t.title), ['New']);
  assert.equal(db.docs.has(QUEUE), false);
  assert.equal(db.docs.get('similarReasks/2026-10-11').n, 1);
  assert.equal(lines.length, 1);
  for (const part of [ID, 'gemini-old', MODEL]) {
    assert.ok(lines[0].includes(part), lines[0]);
  }
  const after = await get(d);
  assert.equal(after.body.model, MODEL);
  assert.equal(after.headers['Cache-Control'], CACHE_CURRENT);
});

test('a pass takes at most its batch, oldest first', quietly(async () => {
  const db = fakeDb();
  const d = deps(db, []);
  d.fetch = async (url) => {
    if (url.startsWith('https://v3-cinemeta.strem.io/')) return AVALON;
    d.asked++;
    return gemini('New');
  };
  const ids = [];
  for (let i = 0; i < REVALIDATE_BATCH + 3; i++) {
    const id = `tt${1000 + i}`;
    ids.push(id);
    storeOldAt(db, id);
    await get(d, id);
    d.clock.t += 1;
  }
  assert.equal(d.asked, 0);
  assert.equal(await revalidatePass(d, KEY), REVALIDATE_BATCH);
  assert.equal(d.asked, REVALIDATE_BATCH);
  const left = [...db.docs.keys()].filter((p) =>
    p.startsWith('similarRevalidate/'));
  assert.deepEqual(left.sort(), ids.slice(REVALIDATE_BATCH)
      .map((id) => `similarRevalidate/v${QUESTION_VERSION}_movie_${id}`));
  assert.equal(await revalidatePass(d, KEY), 3);
}));

test('a pass stops at the day\'s cap, and the next day goes on',
    quietly(async () => {
      const db = fakeDb();
      const d = deps(db, []);
      d.fetch = async (url) => {
        if (url.startsWith('https://v3-cinemeta.strem.io/')) return AVALON;
        d.asked++;
        return gemini('New');
      };
      for (const id of ['tt1', 'tt2', 'tt3']) {
        storeOldAt(db, id);
        await get(d, id);
      }
      db.docs.set('similarReasks/2026-10-11', {n: REASK_CAP - 1});
      assert.equal(await revalidatePass(d, KEY), 1);
      assert.equal(db.docs.get('similarReasks/2026-10-11').n, REASK_CAP);
      assert.equal(await revalidatePass(d, KEY), 0);
      assert.equal(d.asked, 1);
      d.clock.t += 24 * 60 * 60 * 1000;
      assert.equal(await revalidatePass(d, KEY), 2);
      assert.equal(d.asked, 3);
    }));

test('a failed re-ask keeps the answer and the queue entry, a few times',
    quietly(async () => {
      const db = fakeDb();
      storeOld(db);
      const d = deps(db, [response(500, {}), response(500, {}),
        response(500, {}), gemini('Never')]);
      await get(d);
      for (let pass = 1; pass <= REVALIDATE_TRIES; pass++) {
        d.clock.t += CLAIM_SECONDS * 1000 + 1;
        await revalidatePass(d, KEY);
        assert.equal(db.docs.get(DOC).model, 'gemini-old');
        assert.deepEqual(db.docs.get(DOC).titles.map((t) => t.title), ['Old']);
        assert.equal(db.docs.has(QUEUE), pass < REVALIDATE_TRIES, `pass ${pass}`);
      }
      assert.equal(d.asked, REVALIDATE_TRIES);
    }));

test('a title held by a claim is left for the next pass', quietly(async () => {
  const db = fakeDb();
  storeOld(db);
  const d = deps(db, [response(500, {}), gemini('New')]);
  await get(d);
  await revalidatePass(d, KEY);
  await revalidatePass(d, KEY);
  assert.equal(d.asked, 1, 'held while the claim stands');
  d.clock.t += CLAIM_SECONDS * 1000 + 1;
  await revalidatePass(d, KEY);
  assert.equal(d.asked, 2);
  assert.equal(db.docs.get(DOC).model, MODEL);
}));

test('a queued title already re-answered just leaves the queue', async () => {
  const db = fakeDb();
  storeOld(db);
  const d = deps(db, []);
  await get(d);
  db.docs.set(DOC, {...db.docs.get(DOC), model: MODEL});
  assert.equal(await revalidatePass(d, KEY), 0);
  assert.equal(d.asked, 0);
  assert.equal(db.docs.has(QUEUE), false);
});

test('the key is never logged', async () => {
  const lines = [];
  const [log, warn] = [console.log, console.warn];
  console.log = console.warn = (...args) => lines.push(args.join(' '));
  try {
    const db = fakeDb();
    // A first ask failing with the key in the error, and a re-ask doing so.
    await get(deps(db, [new TypeError(`fetch failed key=${KEY}`)]));
    storeOld(db);
    const d = deps(db, [new TypeError(`fetch failed key=${KEY}`)]);
    await get(d);
    await revalidatePass(d, KEY);
  } finally {
    console.log = log;
    console.warn = warn;
  }
  assert.ok(lines.length >= 2);
  for (const line of lines) assert.ok(!line.includes(KEY), line);
});

test('oldest queued first, whatever order they were written in',
    quietly(async () => {
      const db = fakeDb();
      const d = deps(db, []);
      d.fetch = async (url) => {
        if (url.startsWith('https://v3-cinemeta.strem.io/')) return AVALON;
        d.asked++;
        return gemini('New');
      };
      // Written newest first.
      for (const [id, markedAt] of [['tt3', 30], ['tt2', 20], ['tt1', 10]]) {
        storeOldAt(db, id);
        db.docs.set(`similarRevalidate/v${QUESTION_VERSION}_movie_${id}`,
            {type: 'movie', id, markedAt, tries: 0});
      }
      assert.equal(await revalidatePass(d, KEY, 1), 1);
      assert.equal(db.docs.get(`similar/v${QUESTION_VERSION}_movie_tt1`).model,
          MODEL);
      assert.equal(db.docs.get(`similar/v${QUESTION_VERSION}_movie_tt3`).model,
          'gemini-old');
    }));

test('a cap another pass spent meanwhile stops this one', quietly(async () => {
  const db = fakeDb();
  const d = deps(db, []);
  d.fetch = async (url) => {
    if (url.startsWith('https://v3-cinemeta.strem.io/')) return AVALON;
    d.asked++;
    // Another pass, overlapping this one, spends the rest of the day.
    db.docs.set('similarReasks/2026-10-11', {n: REASK_CAP});
    return gemini('New');
  };
  for (const id of ['tt1', 'tt2', 'tt3']) {
    storeOldAt(db, id);
    await get(d, id);
  }
  assert.equal(await revalidatePass(d, KEY), 1);
  assert.equal(d.asked, 1);
  assert.equal(db.docs.get('similarReasks/2026-10-11').n, REASK_CAP);
}));
