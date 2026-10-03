// `node --test` from functions/: the ratings route against a Firestore and
// an MDBList that live in this file. Nothing here needs node_modules.

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  handler,
  ratingsFor,
  scoresIn,
  FRESH_DAYS,
  EMPTY_DAYS,
  RETRY_MINUTES,
  LIMIT_DOC,
} = require('../ratings');

const DAY = 24 * 60 * 60 * 1000;
const KEY = 'the-secret-key';

/**
 * The part of Firestore the route uses, kept in a Map. A transaction is
 * optimistic, as Firestore's is: one whose reads changed under it before
 * it commits is run again.
 */
function fakeDb() {
  const docs = new Map();
  const versions = new Map();
  const write = (path, data) => {
    docs.set(path, structuredClone(data));
    versions.set(path, (versions.get(path) ?? 0) + 1);
  };
  const ref = (path) => ({
    path,
    async get() {
      return snapshot(path);
    },
    async set(data) {
      write(path, data);
    },
  });
  const snapshot = (path) => ({
    exists: docs.has(path),
    data: () => structuredClone(docs.get(path)),
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

/** A Jaws-shaped MDBList answer, the documented example plus popcorn. */
const JAWS = {
  title: 'Jaws',
  ratings: [
    {source: 'imdb', value: 8.1, score: 81, votes: 673852, url: 99},
    {source: 'metacritic', value: 87, score: 87, votes: 21, url: '/jaws'},
    {source: 'tomatoes', value: 97, score: 97, votes: 102, url: '/m/jaws'},
    {source: 'tmdb', value: 76, score: 76, votes: 10114, url: null},
    {source: 'popcorn', value: 90, score: 90, votes: 250000, url: null},
    {source: 'letterboxd', value: 8, score: 80, votes: 876082},
  ],
};

function response(status, body, headers = {}) {
  const lower = Object.fromEntries(
      Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return {
    status,
    ok: status >= 200 && status < 300,
    headers: {get: (name) => lower[name.toLowerCase()] ?? null},
    json: async () => {
      if (typeof body === 'string') throw new SyntaxError('not json');
      return body;
    },
  };
}

/** Deps over [db] whose MDBList answers [answers] in turn. */
function deps(db, answers, clock = {t: Date.UTC(2026, 9, 3)}) {
  const calls = [];
  return {
    calls,
    clock,
    db,
    now: () => clock.t,
    sleep: async (ms) => {
      clock.t += ms;
    },
    fetch: async (url, init) => {
      calls.push(url);
      const next = answers.shift();
      if (next instanceof Error) throw next;
      if (typeof next === 'function') return next();
      return next;
    },
  };
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

async function ask(d, type, id) {
  const res = fakeRes();
  await handler({value: () => KEY}, () => d)({params: {type, id}}, res);
  return res;
}

test('scoresIn keeps the four, on the scales the app shows', () => {
  assert.deepEqual(scoresIn(JAWS), {
    imdb: {score: 8.1, votes: 673852},
    tmdb: {score: 7.6, votes: 10114},
    tomatoes: {score: 97, votes: 102},
    popcorn: {score: 90, votes: 250000},
  });
});

test('scoresIn turns a missing, null or zero score into null', () => {
  assert.deepEqual(scoresIn({ratings: [
    {source: 'imdb', value: null, score: null, votes: null},
    {source: 'tomatoes', value: 0, score: 0, votes: 0},
    {source: 'popcorn', value: 61, score: 61, votes: null},
  ]}), {
    imdb: null,
    tmdb: null,
    tomatoes: null,
    popcorn: {score: 61},
  });
  assert.deepEqual(scoresIn({}), {
    imdb: null, tmdb: null, tomatoes: null, popcorn: null,
  });
});

test('the first ask fetches, answers the wire shape, and is cached', async () => {
  const db = fakeDb();
  const d = deps(db, [response(200, JAWS)]);
  const res = await ask(d, 'movie', 'tt0073195');
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, {
    imdb: {score: 8.1, votes: 673852},
    tmdb: {score: 7.6, votes: 10114},
    tomatoes: {score: 97, votes: 102},
    popcorn: {score: 90, votes: 250000},
    fetchedAt: new Date(d.clock.t).toISOString(),
  });
  assert.equal(res.headers['Cache-Control'],
      'public, max-age=86400, s-maxage=86400');
  assert.deepEqual(d.calls,
      [`https://api.mdblist.com/imdb/movie/tt0073195?apikey=${KEY}`]);

  // A second ask is a read.
  const again = await ask(d, 'movie', 'tt0073195');
  assert.deepEqual(again.body, res.body);
  assert.equal(d.calls.length, 1);
});

test('a series is asked about as a show', async () => {
  const d = deps(fakeDb(), [response(200, JAWS)]);
  await ask(d, 'series', 'tt0903747');
  assert.deepEqual(d.calls,
      [`https://api.mdblist.com/imdb/show/tt0903747?apikey=${KEY}`]);
});

test('anything but a movie or series tt id is refused unasked', async () => {
  for (const [type, id] of [
    ['show', 'tt0073195'],
    ['channel', 'tt0073195'],
    ['movie', 'tt0073195?apikey=x'],
    ['movie', '../user'],
    ['movie', 'kitsu:1'],
    ['movie', 'tt'],
    ['__proto__', 'tt1'],
  ]) {
    const d = deps(fakeDb(), []);
    const res = await ask(d, type, id);
    assert.equal(res.statusCode, 400, `${type} ${id}`);
    assert.equal(d.calls.length, 0);
  }
});

test('a fresh answer is served for FRESH_DAYS, then fetched again', async () => {
  const db = fakeDb();
  const changed = structuredClone(JAWS);
  changed.ratings[0].value = 8.2;
  const d = deps(db, [response(200, JAWS), response(200, changed)]);
  await ask(d, 'movie', 'tt0073195');
  d.clock.t += FRESH_DAYS * DAY - 1;
  assert.equal((await ask(d, 'movie', 'tt0073195')).body.imdb.score, 8.1);
  assert.equal(d.calls.length, 1);
  d.clock.t += 2;
  assert.equal((await ask(d, 'movie', 'tt0073195')).body.imdb.score, 8.2);
  assert.equal(d.calls.length, 2);
});

test('an answer with no scores is kept for EMPTY_DAYS only', async () => {
  const db = fakeDb();
  const d = deps(db, [response(404, {error: 'Not found'}),
    response(200, JAWS)]);
  const first = await ask(d, 'movie', 'tt9999999');
  assert.equal(first.body.imdb, null);
  assert.notEqual(first.body.fetchedAt, null, 'a 404 is an answer');
  d.clock.t += EMPTY_DAYS * DAY - 1;
  await ask(d, 'movie', 'tt9999999');
  assert.equal(d.calls.length, 1);
  d.clock.t += 2;
  assert.equal((await ask(d, 'movie', 'tt9999999')).body.imdb.score, 8.1);
});

test('a 429 serves the stale answer and stops every fetch until the reset',
    async () => {
      const db = fakeDb();
      const d = deps(db, [response(200, JAWS)]);
      await ask(d, 'movie', 'tt0073195');
      const fetchedAt = new Date(d.clock.t).toISOString();
      d.clock.t += FRESH_DAYS * DAY + 1;
      const reset = Math.floor(d.clock.t / 1000) + 3600;
      d.calls.length = 0;
      const limited = () => response(429,
          {error: 'Daily API limit exceeded!'},
          {'X-RateLimit-Reset': String(reset)});
      // Answers past the first are never used: nothing may ask again.
      const answers = [limited(), limited(), limited()];
      d.fetch = async (url) => {
        d.calls.push(url);
        return answers.shift();
      };

      const stale = await ask(d, 'movie', 'tt0073195');
      assert.equal(stale.body.imdb.score, 8.1);
      assert.equal(stale.body.fetchedAt, fetchedAt);
      assert.equal(stale.headers['Cache-Control'],
          'public, max-age=600, s-maxage=600');
      assert.equal(db.docs.get(`ratings/${LIMIT_DOC}`).until, reset * 1000);

      // Another title, never asked: an empty answer, and no fetch.
      const other = await ask(d, 'series', 'tt0903747');
      assert.deepEqual(other.body, {
        imdb: null, tmdb: null, tomatoes: null, popcorn: null,
        fetchedAt: null,
      });
      // The same title, past its retry hold but before the reset.
      d.clock.t += RETRY_MINUTES * 60 * 1000 - 1000;
      await ask(d, 'movie', 'tt0073195');
      assert.equal(d.calls.length, 1, 'one call, then none until the reset');
    });

test('a 429 with only Retry-After holds that long', async () => {
  const db = fakeDb();
  const d = deps(db, [response(429, {}, {'Retry-After': '120'})]);
  const start = d.clock.t;
  await ask(d, 'movie', 'tt0073195');
  assert.equal(db.docs.get(`ratings/${LIMIT_DOC}`).until, start + 120000);
});

test('a failure holds the title back RETRY_MINUTES, then asks again',
    async () => {
      const db = fakeDb();
      const d = deps(db, [response(500, 'oops'), new TypeError('fetch failed'),
        response(200, 'not json'), response(200, JAWS)]);
      const empty = await ask(d, 'movie', 'tt0073195');
      assert.equal(empty.statusCode, 200);
      assert.equal(empty.body.fetchedAt, null);
      assert.equal(empty.body.imdb, null);
      await ask(d, 'movie', 'tt0073195');
      assert.equal(d.calls.length, 1, 'held back');
      d.clock.t += RETRY_MINUTES * 60 * 1000 + 1;
      await ask(d, 'movie', 'tt0073195');
      assert.equal(d.calls.length, 2, 'an unreachable MDBList is a failure');
      d.clock.t += RETRY_MINUTES * 60 * 1000 + 1;
      await ask(d, 'movie', 'tt0073195');
      assert.equal(d.calls.length, 3, 'so is an answer that is not JSON');
      d.clock.t += RETRY_MINUTES * 60 * 1000 + 1;
      assert.equal((await ask(d, 'movie', 'tt0073195')).body.imdb.score, 8.1);
    });

test('two first asks at once pay for one fetch', async () => {
  const db = fakeDb();
  let release;
  const gate = new Promise((resolve) => (release = resolve));
  const d = deps(db, [async () => {
    await gate;
    return response(200, JAWS);
  }]);
  // The waiter's sleep is where the fetch gets to finish.
  d.sleep = async (ms) => {
    d.clock.t += ms;
    release();
    await new Promise((resolve) => setImmediate(resolve));
  };
  const [a, b] = await Promise.all([
    ratingsFor(d, KEY, 'movie', 'tt0073195'),
    ratingsFor(d, KEY, 'movie', 'tt0073195'),
  ]);
  assert.equal(d.calls.length, 1);
  assert.equal(a.answer.ratings.imdb.score, 8.1);
  assert.equal(b.answer.ratings.imdb.score, 8.1);
});

test('the key is never logged', async () => {
  const lines = [];
  const warn = console.warn;
  console.warn = (...args) => lines.push(args.join(' '));
  try {
    const leaky = new TypeError(`fetch failed for apikey=${KEY}`);
    const d = deps(fakeDb(), [leaky]);
    await ask(d, 'movie', 'tt0073195');
    d.clock.t += RETRY_MINUTES * 60 * 1000 + 1;
    d.fetch = async () => response(403, {error: `Invalid API key ${KEY}`});
    await ask(d, 'movie', 'tt0073195');
  } finally {
    console.warn = warn;
  }
  assert.equal(lines.length, 2);
  for (const line of lines) assert.ok(!line.includes(KEY), line);
});

test('a failing store still answers, empty and not edge-cached for long',
    async () => {
      const d = deps({
        collection: () => ({doc: () => ({})}),
        runTransaction: async () => {
          throw new Error('unavailable');
        },
      }, []);
      const warn = console.warn;
      console.warn = () => {};
      let res;
      try {
        res = await ask(d, 'movie', 'tt0073195');
      } finally {
        console.warn = warn;
      }
      assert.equal(res.statusCode, 200);
      assert.equal(res.body.fetchedAt, null);
      assert.equal(res.headers['Cache-Control'],
          'public, max-age=600, s-maxage=600');
    });
