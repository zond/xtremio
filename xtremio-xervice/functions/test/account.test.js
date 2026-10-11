// `node --test` from functions/: the account routes against a Firestore and
// a Stremio API that live in this file. Nothing here needs node_modules.

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  identityHandler,
  withAccount,
  facesRoutes,
  vaultRoutes,
  seal,
  unseal,
  FACES_LIMIT,
  signToken,
  verifyToken,
  logName,
  TOKEN_SECONDS,
  IDENTITY_PER_HOUR,
  STREMIO_GET_USER,
} = require('../account');

const IDENTITY_KEY = 'identity-key-for-tests';
const AUTH_KEY = 'stremio-session-key-0123456789';
const USER = '5f2a0c3b9d1e4a0012345678';

/** The part of Firestore the routes use, kept in a Map. */
function fakeDb() {
  const docs = new Map();
  const ref = (path) => ({
    path,
    async get() {
      return snapshot(path);
    },
    async set(data, options) {
      const before = options?.merge ? docs.get(path) ?? {} : {};
      docs.set(path, structuredClone({...before, ...data}));
    },
    async delete() {
      docs.delete(path);
    },
    collection: (name) => ({doc: (id) => ref(`${path}/${name}/${id}`)}),
  });
  const snapshot = (path) => ({
    exists: docs.has(path),
    data: () => structuredClone(docs.get(path)),
  });
  return {
    docs,
    collection: (name) => ({doc: (id) => ref(`${name}/${id}`)}),
    async runTransaction(fn) {
      const writes = [];
      const result = await fn({
        get: async (r) => snapshot(r.path),
        set: (r, data) => writes.push([r.path, data]),
      });
      for (const [path, data] of writes) docs.set(path, structuredClone(data));
      return result;
    },
  };
}

function response(status, body) {
  return {
    status,
    ok: status >= 200 && status < 300,
    json: async () => {
      if (typeof body === 'string') throw new SyntaxError('not json');
      return body;
    },
  };
}

/** Deps whose Stremio answers [answers] in turn. */
function deps(answers = [], clock = {t: Date.UTC(2026, 9, 11, 12)}) {
  const calls = [];
  return {
    calls,
    clock,
    db: fakeDb(),
    now: () => clock.t,
    fetch: async (url, init) => {
      calls.push({url, init});
      const next = answers.shift();
      if (next instanceof Error) throw next;
      return next;
    },
  };
}

function fakeRes() {
  return {
    statusCode: 200,
    headers: {},
    body: undefined,
    headersSent: false,
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
      this.headersSent = true;
      return this;
    },
  };
}

const GRANT_KEY = Buffer.alloc(32, 7).toString('base64');
const keys = {
  identity: {value: () => IDENTITY_KEY},
  grant: {value: () => GRANT_KEY},
};

async function identify(d, authKey = AUTH_KEY, headers = {}) {
  const res = fakeRes();
  await identityHandler(keys, () => d)(
      {body: {authKey}, headers, ip: '10.0.0.1'}, res);
  return res;
}

/** Captures console output for the length of [fn]. */
async function quietly(fn) {
  const lines = [];
  const saved = [console.log, console.warn, console.error];
  console.log = console.warn = console.error =
    (...args) => lines.push(args.join(' '));
  try {
    await fn();
  } finally {
    [console.log, console.warn, console.error] = saved;
  }
  return lines;
}

test('a key Stremio knows is a token naming its user, for an hour',
    async () => {
      const d = deps([response(200, {result: {
        _id: USER, email: 'someone@example.com', avatar: null,
      }})]);
      let res;
      const lines = await quietly(async () => {
        res = await identify(d);
      });
      assert.equal(res.statusCode, 200);
      assert.equal(res.headers['Cache-Control'], 'no-store, max-age=0');
      assert.equal(res.body.expiresAt,
          new Date(d.clock.t + TOKEN_SECONDS * 1000).toISOString());
      assert.equal(verifyToken(IDENTITY_KEY, res.body.token, d.clock.t), USER);
      // Stremio was asked the way stremio-core asks it.
      assert.equal(d.calls.length, 1);
      assert.equal(d.calls[0].url, STREMIO_GET_USER);
      assert.equal(d.calls[0].init.method, 'POST');
      assert.deepEqual(JSON.parse(d.calls[0].init.body),
          {type: 'GetUser', authKey: AUTH_KEY});
      // The token carries the id and nothing of the key or the e-mail.
      const payload = Buffer.from(res.body.token.split('.')[1], 'base64url')
          .toString('utf8');
      assert.ok(!payload.includes(AUTH_KEY));
      assert.ok(!payload.includes('someone@example.com'));
      // Nothing is stored but the rate counter.
      for (const path of d.db.docs.keys()) assert.match(path, /^rate\//);
      // The log names the account by a hash, never the key or the id.
      assert.deepEqual(lines, [`identity: account ${logName(USER)}`]);
    });

test('a key Stremio refuses is a 401, and so is an answer with no id',
    async () => {
      for (const answer of [
        response(200, {error: {message: 'Session not found', code: 1}}),
        response(401, {}),
      ]) {
        const d = deps([answer]);
        let res;
        await quietly(async () => {
          res = await identify(d);
        });
        assert.equal(res.statusCode, 401);
        assert.equal(res.body.token, undefined);
      }
    });

test('a Stremio that does not answer is a 502, not a 401', async () => {
  for (const answer of [new TypeError('fetch failed'), response(500, 'x'),
    response(200, 'not json'), response(200, {result: {}})]) {
    const d = deps([answer]);
    let res;
    await quietly(async () => {
      res = await identify(d);
    });
    assert.equal(res.statusCode, 502);
  }
});

test('no key, or not a string, is refused unasked', async () => {
  for (const authKey of [null, '', 42, 'x'.repeat(513)]) {
    const d = deps();
    const res = await identify(d, authKey);
    assert.equal(res.statusCode, 400);
    assert.equal(d.calls.length, 0);
  }
});

test('the auth key is never logged, whatever Stremio says', async () => {
  const leaky = new TypeError(`fetch failed for ${AUTH_KEY}`);
  const lines = await quietly(async () => {
    await identify(deps([leaky]));
    await identify(deps([response(200, {error: {message: AUTH_KEY}})]));
    await identify(deps([response(200, {result: {_id: USER}})]));
  });
  assert.equal(lines.length, 3);
  for (const line of lines) {
    assert.ok(!line.includes(AUTH_KEY), line);
    assert.ok(!line.includes(USER), line);
  }
});

test('one address is held to IDENTITY_PER_HOUR an hour', async () => {
  const d = deps();
  d.fetch = async () => response(200, {result: {_id: USER}});
  const headers = {'x-forwarded-for': '203.0.113.9, 10.0.0.1'};
  await quietly(async () => {
    for (let i = 0; i < IDENTITY_PER_HOUR; i++) {
      assert.equal((await identify(d, AUTH_KEY, headers)).statusCode, 200);
    }
    assert.equal((await identify(d, AUTH_KEY, headers)).statusCode, 429);
    // Another caller has a bucket of its own.
    assert.equal((await identify(d, AUTH_KEY,
        {'x-forwarded-for': '198.51.100.7'})).statusCode, 200);
    // And the next hour is a new one.
    d.clock.t += 3600 * 1000;
    assert.equal((await identify(d, AUTH_KEY, headers)).statusCode, 200);
  });
});

test('a token verifies until it expires, and not with another key', () => {
  const now = Date.UTC(2026, 9, 11);
  const token = signToken(IDENTITY_KEY, USER, now + 1000);
  assert.equal(verifyToken(IDENTITY_KEY, token, now), USER);
  assert.equal(verifyToken(IDENTITY_KEY, token, now + 999), USER);
  assert.equal(verifyToken(IDENTITY_KEY, token, now + 1000), null);
  assert.equal(verifyToken('another key', token, now), null);
  // A payload changed under the signature is refused.
  const [v, , signature] = token.split('.');
  const forged = Buffer.from(JSON.stringify({sub: 'someone-else',
    exp: now + 1000})).toString('base64url');
  assert.equal(verifyToken(IDENTITY_KEY, `${v}.${forged}.${signature}`, now),
      null);
  for (const junk of [undefined, '', 'v1', 'v1.a.b', 'v2.a.b', token + 'x']) {
    assert.equal(verifyToken(IDENTITY_KEY, junk, now), null, String(junk));
  }
});

test('a route behind a token runs for its account, and only then',
    async () => {
      const d = deps();
      const seen = [];
      const route = withAccount(keys, () => d, async (req, res, sub) => {
        seen.push(sub);
        res.json({ok: true});
      });
      const call = async (authorization) => {
        const res = fakeRes();
        await route({method: 'GET', path: '/x',
          headers: authorization ? {authorization} : {}}, res);
        return res;
      };
      const live = signToken(IDENTITY_KEY, USER, d.clock.t + 1000);
      assert.equal((await call(`Bearer ${live}`)).statusCode, 200);
      assert.deepEqual(seen, [USER]);
      const expired = signToken(IDENTITY_KEY, USER, d.clock.t);
      for (const header of [undefined, `Bearer ${expired}`, live,
        `Bearer ${signToken('wrong', USER, d.clock.t + 1000)}`]) {
        const res = await call(header);
        assert.equal(res.statusCode, 401, String(header));
        assert.equal(res.headers['Cache-Control'], 'no-store, max-age=0');
      }
      assert.deepEqual(seen, [USER]);
    });

/** Calls one faces route as [user] (null for no token). */
async function facesCall(d, verb, user, body) {
  const routes = facesRoutes(keys, () => d);
  const res = fakeRes();
  const headers = user ?
    {authorization: `Bearer ${signToken(IDENTITY_KEY, user,
        d.clock.t + 60000)}`} :
    {};
  await quietly(async () => {
    await routes[verb]({method: verb.toUpperCase(), path: '/faces', headers,
      body}, res);
  });
  return res;
}

test('a first PUT keeps what the device sent, and GET reads it back',
    async () => {
      const d = deps();
      const sent = {faces: {
        tt1: {kind: 'like', at: 100},
        tt2: {kind: 'dislike', at: 200},
        'kitsu:7': {kind: 'dismissed', at: 300},
      }};
      const put = await facesCall(d, 'put', USER, sent);
      assert.equal(put.statusCode, 200);
      assert.deepEqual(put.body, {faces: sent.faces, clearedAt: 0});
      assert.deepEqual(d.db.docs.get(`faces/${USER}`),
          {faces: sent.faces, clearedAt: 0});
      const got = await facesCall(d, 'get', USER);
      assert.deepEqual(got.body, put.body);
      assert.equal(got.headers['Cache-Control'], 'no-store, max-age=0');
    });

test('a PUT merges: newest per title wins, and nothing is dropped',
    async () => {
      const d = deps();
      await facesCall(d, 'put', USER, {faces: {
        tt1: {kind: 'like', at: 100},
        tt2: {kind: 'dislike', at: 500},
        tt3: {kind: 'like', at: 100},
      }});
      const put = await facesCall(d, 'put', USER, {faces: {
        tt1: {kind: 'none', at: 200}, // newer: the like was taken off
        tt2: {kind: 'like', at: 400}, // older: the dislike stands
        tt4: {kind: 'dismissed', at: 50}, // only here: kept
      }});
      assert.deepEqual(put.body.faces, {
        tt1: {kind: 'none', at: 200},
        tt2: {kind: 'dislike', at: 500},
        tt3: {kind: 'like', at: 100},
        tt4: {kind: 'dismissed', at: 50},
      });
    });

test('DELETE forgets everything, and an older set cannot bring it back',
    async () => {
      const d = deps();
      await facesCall(d, 'put', USER, {faces: {tt1: {kind: 'like', at: 100}}});
      const forgotten = await facesCall(d, 'delete', USER);
      assert.deepEqual(forgotten.body, {faces: {}, clearedAt: d.clock.t});
      // A device that has not heard sends what it had, and one mark newer
      // than the forgetting.
      const put = await facesCall(d, 'put', USER, {faces: {
        tt1: {kind: 'like', at: 100},
        tt9: {kind: 'like', at: d.clock.t + 1},
      }, clearedAt: 0});
      assert.deepEqual(put.body, {
        faces: {tt9: {kind: 'like', at: d.clock.t + 1}},
        clearedAt: d.clock.t,
      });
    });

test('faces are kept per account, and refused without a token', async () => {
  const d = deps();
  await facesCall(d, 'put', USER, {faces: {tt1: {kind: 'like', at: 1}}});
  const other = await facesCall(d, 'get', 'another-user');
  assert.deepEqual(other.body, {faces: {}, clearedAt: 0});
  for (const verb of ['get', 'put', 'delete']) {
    const res = await facesCall(d, verb, null, {faces: {}});
    assert.equal(res.statusCode, 401, verb);
  }
  assert.deepEqual(d.db.docs.get(`faces/${USER}`).faces,
      {tt1: {kind: 'like', at: 1}});
});

test('rows that are not faces are dropped, a body that is not a set refused',
    async () => {
      const d = deps();
      const put = await facesCall(d, 'put', USER, {faces: {
        'tt1': {kind: 'love', at: 1},
        'tt2': {kind: 'like', at: -1},
        'tt3': {kind: 'like', at: '5'},
        '../x': {kind: 'like', at: 1},
        'tt4': {kind: 'like', at: 4},
      }});
      assert.deepEqual(put.body.faces, {tt4: {kind: 'like', at: 4}});
      for (const body of [{faces: []}, {faces: 'x'}, []]) {
        assert.equal((await facesCall(d, 'put', USER, body)).statusCode, 400);
      }
      const many = {};
      for (let i = 0; i <= FACES_LIMIT; i++) {
        many[`tt${i}`] = {kind: 'like', at: 1};
      }
      assert.equal((await facesCall(d, 'put', USER, {faces: many})).statusCode,
          413);
    });

const REFRESH = '1//0g-a-refresh-token-for-tests';

/** Calls one vault route as [user] (null for no token). */
async function vaultCall(d, verb, user, body, lines = []) {
  const routes = vaultRoutes(keys, () => d);
  const res = fakeRes();
  const headers = user ?
    {authorization: `Bearer ${signToken(IDENTITY_KEY, user,
        d.clock.t + 60000)}`} :
    {};
  lines.push(...await quietly(async () => {
    await routes[verb]({method: verb.toUpperCase(), path: '/vault/drive',
      headers, body}, res);
  }));
  return res;
}

test('a grant is stored sealed, and handed back only to its account',
    async () => {
      const d = deps();
      const lines = [];
      const put = await vaultCall(d, 'put', USER, {refreshToken: REFRESH},
          lines);
      assert.equal(put.statusCode, 200);
      assert.equal(put.body.storedAt, new Date(d.clock.t).toISOString());
      const stored = d.db.docs.get(`vault/${USER}`);
      assert.ok(!JSON.stringify(stored).includes(REFRESH), 'sealed at rest');
      assert.deepEqual(Object.keys(stored.drive).sort(),
          ['data', 'iv', 'storedAt', 'tag']);

      const got = await vaultCall(d, 'get', USER, undefined, lines);
      assert.equal(got.statusCode, 200);
      assert.equal(got.body.refreshToken, REFRESH);
      assert.equal(got.headers['Cache-Control'], 'no-store, max-age=0');

      // Another account has none, and no token is no grant.
      assert.equal((await vaultCall(d, 'get', 'another-user')).statusCode, 404);
      for (const verb of ['get', 'put', 'delete']) {
        const res = await vaultCall(d, verb, null, {refreshToken: 'x'});
        assert.equal(res.statusCode, 401, verb);
      }
      for (const line of lines) assert.ok(!line.includes(REFRESH), line);
    });

test('each write is sealed with a fresh IV', async () => {
  const d = deps();
  await vaultCall(d, 'put', USER, {refreshToken: REFRESH});
  const first = d.db.docs.get(`vault/${USER}`).drive;
  await vaultCall(d, 'put', USER, {refreshToken: REFRESH});
  const second = d.db.docs.get(`vault/${USER}`).drive;
  assert.notEqual(first.iv, second.iv);
  assert.notEqual(first.data, second.data);
});

test('a sealed grant opens only under its account and its key', () => {
  const sealed = seal(GRANT_KEY, REFRESH, USER);
  assert.equal(unseal(GRANT_KEY, sealed, USER), REFRESH);
  assert.throws(() => unseal(GRANT_KEY, sealed, 'another-user'));
  assert.throws(() =>
    unseal(Buffer.alloc(32, 8).toString('base64'), sealed, USER));
  assert.throws(() => seal('too-short', REFRESH, USER), /32 bytes/);
});

test('DELETE forgets the grant everywhere', async () => {
  const d = deps();
  await vaultCall(d, 'put', USER, {refreshToken: REFRESH});
  const gone = await vaultCall(d, 'delete', USER);
  assert.deepEqual(gone.body, {ok: true});
  assert.equal(d.db.docs.has(`vault/${USER}`), false);
  assert.equal((await vaultCall(d, 'get', USER)).statusCode, 404);
});

test('a PUT with no token is refused, and stores nothing', async () => {
  const d = deps();
  for (const body of [{}, {refreshToken: ''}, {refreshToken: 5},
    {refreshToken: 'x'.repeat(4097)}]) {
    assert.equal((await vaultCall(d, 'put', USER, body)).statusCode, 400);
  }
  assert.equal(d.db.docs.has(`vault/${USER}`), false);
});
