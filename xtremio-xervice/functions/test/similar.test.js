// `node --test` from functions/: the similar route against a Firestore, a
// Cinemeta and a Gemini that live in this file. Nothing here needs
// node_modules.

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  handler,
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
    collection: (name) => ({doc: (id) => ref(`${name}/${id}`)}),
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

test('another model\'s answer is served at once and re-asked once',
    quietly(async () => {
      const db = fakeDb();
      storeOld(db);
      let release;
      const gate = new Promise((resolve) => (release = resolve));
      const d = deps(db, []);
      d.fetch = async (url) => {
        if (url.startsWith('https://v3-cinemeta.strem.io/')) return AVALON;
        d.asked++;
        await gate;
        return gemini('New');
      };
      // The re-ask is held open; the viewer's answer is already out.
      const res = fakeRes();
      const first = handler({value: () => KEY}, () => d)(
          {params: {type: 'movie', id: ID}}, res);
      await new Promise((resolve) => setImmediate(resolve));
      assert.deepEqual(res.body.titles.map((t) => t.title), ['Old']);
      assert.equal(res.body.model, 'gemini-old');
      assert.equal(res.headers['Cache-Control'], CACHE_STALE);

      // A second request while the re-ask is out is served the old answer
      // and does not ask again.
      const secondRes = fakeRes();
      const second = handler({value: () => KEY}, () => d)(
          {params: {type: 'movie', id: ID}}, secondRes);
      for (let turn = 0; turn < 5; turn++) {
        await new Promise((resolve) => setImmediate(resolve));
      }
      assert.deepEqual(secondRes.body.titles.map((t) => t.title), ['Old']);
      assert.equal(d.asked, 1);

      release();
      await Promise.all([first, second]);
      const doc = db.docs.get(DOC);
      assert.equal(doc.model, MODEL);
      assert.deepEqual(doc.titles.map((t) => t.title), ['New']);
      assert.equal(db.docs.get('similarReasks/2026-10-11').n, 1);

      const third = await get(d);
      assert.deepEqual(third.body.titles.map((t) => t.title), ['New']);
      assert.equal(third.body.model, MODEL);
      assert.equal(third.headers['Cache-Control'], CACHE_CURRENT);
      assert.equal(d.asked, 1);
    }));

test('one log line per re-ask names the title and both models',
    async () => {
      const db = fakeDb();
      storeOld(db);
      const lines = [];
      const log = console.log;
      console.log = (...args) => lines.push(args.join(' '));
      try {
        await get(deps(db, [gemini('New')]));
      } finally {
        console.log = log;
      }
      assert.equal(lines.length, 1);
      assert.ok(lines[0].includes(ID), lines[0]);
      assert.ok(lines[0].includes('gemini-old'), lines[0]);
      assert.ok(lines[0].includes(MODEL), lines[0]);
    });

test('past the day\'s cap a stale answer is served and not re-asked',
    async () => {
      const db = fakeDb();
      storeOld(db);
      db.docs.set('similarReasks/2026-10-11', {n: REASK_CAP});
      const d = deps(db, [gemini('New')]);
      const res = await get(d);
      assert.deepEqual(res.body.titles.map((t) => t.title), ['Old']);
      assert.equal(res.headers['Cache-Control'], CACHE_STALE);
      assert.equal(d.asked, 0);
      assert.equal(db.docs.get(DOC).model, 'gemini-old');

      // The next day has a cap of its own.
      d.clock.t += 24 * 60 * 60 * 1000;
      const quiet = console.log;
      console.log = () => {};
      try {
        await get(d);
      } finally {
        console.log = quiet;
      }
      assert.equal(d.asked, 1);
      assert.equal(db.docs.get(DOC).model, MODEL);
    });

test('a failed re-ask keeps the stored answer, and holds the title a while',
    quietly(async () => {
      const db = fakeDb();
      storeOld(db);
      const d = deps(db, [response(500, {}), gemini('New')]);
      const res = await get(d);
      assert.equal(res.statusCode, 200);
      assert.deepEqual(res.body.titles.map((t) => t.title), ['Old']);
      const doc = db.docs.get(DOC);
      assert.equal(doc.status, 'ready');
      assert.equal(doc.model, 'gemini-old');
      assert.deepEqual(doc.titles.map((t) => t.title), ['Old']);

      await get(d);
      assert.equal(d.asked, 1, 'held while the claim stands');
      d.clock.t += CLAIM_SECONDS * 1000 + 1;
      await get(d);
      assert.equal(d.asked, 2);
      assert.equal(db.docs.get(DOC).model, MODEL);
    }));

test('the key is never logged', async () => {
  const lines = [];
  const [log, warn] = [console.log, console.warn];
  console.log = console.warn = (...args) => lines.push(args.join(' '));
  try {
    const db = fakeDb();
    // A first ask failing with the key in the error, and a re-ask doing so.
    await get(deps(db, [new TypeError(`fetch failed key=${KEY}`)]));
    storeOld(db);
    await get(deps(db, [new TypeError(`fetch failed key=${KEY}`)]));
  } finally {
    console.log = log;
    console.warn = warn;
  }
  assert.ok(lines.length >= 2);
  for (const line of lines) assert.ok(!line.includes(KEY), line);
});
