// Plays a rendition's file the way the Cast receiver plays one: a plain
// `<video src>` in Chrome, headless -- not Media Source, which zond's
// Chromecast with Google TV cannot do above 720p -- and seeks in it the way
// the television's remote does (stream-server docs/design/renditions.md
// §2.8). Point it at a file a server is serving, e.g. the one
// `cargo test --test rendition serve -- --ignored` writes
// (rust/tests/rendition.rs).
//
// It checks what a receiver needs of the file:
//   1. it plays: the position moves, nothing errors;
//   2. `seekable` is the whole film, `[0, duration]` -- the file has a
//      length and ranges, so Chrome may seek anywhere in it;
//   3. a seek to SEEK_TO seconds (300 by default, or 80% of a shorter
//      film) is ONE far `Range` -- straight at the slot the `sidx` names --
//      not a walk through the file, and plays on from there.
// Prints every second's state and every request Chrome made for the file;
// exits 1 when any check fails.
//
//   npm install && node drive.mjs <file url> [seek to, seconds]
//
// Needs Chrome: CHROME, else /usr/bin/google-chrome.
import http from 'node:http';
import puppeteer from 'puppeteer-core';

const [url, seekArg] = process.argv.slice(2);
const server = http
  .createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(`<video id="v" muted autoplay src="${url}"></video>`);
  })
  .listen(0, '127.0.0.1');
await new Promise((resolve) => server.on('listening', resolve));
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME || '/usr/bin/google-chrome',
  headless: true,
  args: ['--autoplay-policy=no-user-gesture-required'],
});
const page = await browser.newPage();
// Every request for the file, with the range it asked for.
const requests = [];
const cdp = await page.createCDPSession();
await cdp.send('Network.enable');
cdp.on('Network.requestWillBeSent', (event) => {
  if (event.request.url !== url) return;
  const range = event.request.headers.Range || event.request.headers.range || '';
  const start = Number((/bytes=(\d+)-/.exec(range) || [0, 0])[1]);
  requests.push({ at: Date.now(), range, start });
  console.log(`request ${range || '(whole file)'}`);
});
await page.goto(`http://127.0.0.1:${server.address().port}/`);
const sample = () =>
  page.evaluate(() => {
    const v = document.getElementById('v');
    const quality = v.getVideoPlaybackQuality();
    const ranges = (r) => [...Array(r.length).keys()].map((i) => [+r.start(i).toFixed(2), +r.end(i).toFixed(2)]);
    return {
      time: +v.currentTime.toFixed(2),
      duration: v.duration,
      buffered: ranges(v.buffered),
      seekable: ranges(v.seekable),
      size: [v.videoWidth, v.videoHeight],
      frames: quality.totalVideoFrames,
      dropped: quality.droppedVideoFrames,
      error: v.error && `${v.error.code} ${v.error.message}`,
    };
  });
const failures = [];
const tick = () => new Promise((resolve) => setTimeout(resolve, 1000));

// 1. It plays.
let first;
let last;
for (let i = 0; i < 6; i++) {
  await tick();
  last = await sample();
  first ??= last;
  console.log(JSON.stringify(last));
  if (last.error) break;
}
if (last.error) failures.push(`media error: ${last.error}`);
if (last.time <= first.time) failures.push('the position never moved');

// 2. Seekable is the whole film.
const whole = last.seekable.length === 1 && last.seekable[0][0] <= 0.1 && last.seekable[0][1] >= last.duration - 0.5;
if (!Number.isFinite(last.duration) || !whole) {
  failures.push(`seekable ${JSON.stringify(last.seekable)} is not [0, ${last.duration}]`);
}

// 3. A seek is one far Range.
const target = Number(seekArg) || Math.min(300, Math.floor(last.duration * 0.8));
const before = requests.length;
const furthest = Math.max(0, ...requests.map((request) => request.start));
const seekedAt = Date.now();
await page.evaluate((target) => {
  const v = document.getElementById('v');
  window.seeked = false;
  v.addEventListener('seeked', () => (window.seeked = true), { once: true });
  v.currentTime = target;
}, target);
let seeked = false;
for (let i = 0; i < 20 && !seeked; i++) {
  await tick();
  seeked = await page.evaluate(() => window.seeked);
}
const duringSeek = requests.slice(before).filter((request) => request.at <= Date.now());
for (let i = 0; i < 4; i++) {
  await tick();
  last = await sample();
  console.log(JSON.stringify(last));
}
const jumps = duringSeek.filter((request) => request.start > furthest);
console.log(
  `seek to ${target}s: ${duringSeek.length} request(s) since, ${jumps.length} past what was read before ` +
    `(${jumps.map((request) => request.range).join(', ')}), ${((Date.now() - seekedAt) / 1000).toFixed(1)}s`,
);
if (!seeked) failures.push(`the seek to ${target}s never completed`);
if (jumps.length === 0) failures.push('the seek asked for nothing past what was read');
// A walk through the file is a request per fragment between; a jump is one.
const walked = jumps.filter((request) => request.start < jumps[0]?.start);
if (jumps.length > 3 || walked.length > 0) failures.push(`the seek walked: ${jumps.map((r) => r.range).join(', ')}`);
if (last.error) failures.push(`media error after the seek: ${last.error}`);
if (last.time < target) failures.push(`the position ${last.time} is short of ${target}`);

await browser.close();
server.close();
for (const failure of failures) console.log(`FAILED: ${failure}`);
process.exit(failures.length ? 1 : 0);
