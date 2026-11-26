// `node --test` from functions/: the routes mounted on a real express app
// and asked over HTTP. The other tests call the handlers directly, so this
// is the one that notices express itself reading a path, a body or a
// parameter differently. It needs node_modules for express and nothing else.

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');

const {mountAccount} = require('../account');
const {mountSimilar} = require('../similar');
const {mountRatings} = require('../ratings');

const secret = (value) => ({value: () => value});

/** Routes that refuse before they read anything need no store at all. */
const noDeps = () => ({
  db: null,
  fetch: () => {
    throw new Error('nothing here may fetch');
  },
  now: Date.now,
  sleep: async () => {},
});

/** Serves [app] on a free port for the length of [body]. */
async function serving(app, body) {
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  try {
    await body(`http://127.0.0.1:${server.address().port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

function accountApp() {
  const app = express();
  app.use(express.json({limit: '1mb'}));
  mountAccount(app, {identity: secret('i'), grant: secret('g')}, noDeps);
  return app;
}

test('a post with no body at all is refused, not crashed on', async () => {
  await serving(accountApp(), async (base) => {
    const answer = await fetch(`${base}/identity`, {method: 'POST'});
    assert.equal(answer.status, 400);
    assert.deepEqual(await answer.json(), {error: 'an authKey'});
  });
});

test('a JSON body reaches the handler as an object', async () => {
  await serving(accountApp(), async (base) => {
    const answer = await fetch(`${base}/identity`, {
      method: 'POST',
      headers: {'content-type': 'application/json'},
      body: JSON.stringify({authKey: 7}),
    });
    assert.equal(answer.status, 400);
    assert.deepEqual(await answer.json(), {error: 'an authKey'});
  });
});

test('a body that is not JSON is a 400', async () => {
  await serving(accountApp(), async (base) => {
    const answer = await fetch(`${base}/identity`, {
      method: 'POST',
      headers: {'content-type': 'application/json'},
      body: '{not json',
    });
    assert.equal(answer.status, 400);
  });
});

test('an account route without an identity is a 401', async () => {
  await serving(accountApp(), async (base) => {
    for (const [method, path] of [
      ['GET', '/faces'], ['PUT', '/faces'], ['DELETE', '/faces'],
      ['GET', '/vault/drive'], ['PUT', '/vault/drive'],
      ['DELETE', '/vault/drive'],
    ]) {
      const answer = await fetch(`${base}${path}`, {method});
      assert.equal(answer.status, 401, `${method} ${path}`);
      assert.deepEqual(await answer.json(), {error: 'identity needed'});
    }
  });
});

test('the path parameters of similar and ratings are read', async () => {
  const app = express();
  mountSimilar(app, secret('k'), noDeps);
  mountRatings(app, secret('k'), noDeps);
  await serving(app, async (base) => {
    for (const path of ['/similar/movie/nonsense', '/ratings/series/nope']) {
      const answer = await fetch(`${base}${path}`);
      assert.equal(answer.status, 400, path);
      assert.deepEqual(await answer.json(),
          {error: 'a Cinemeta movie or series id'});
    }
    const missing = await fetch(`${base}/similar/movie`);
    assert.equal(missing.status, 404);
  });
});
