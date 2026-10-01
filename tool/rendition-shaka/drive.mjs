// Plays a rendition the way the Cast receiver does, in headless Chrome:
// the Shaka Player version the receiver framework loads by default, with
// its configuration (page.html), against a playlist URL a server is
// serving -- e.g. the one `cargo test --test rendition serve -- --ignored`
// writes (rust/tests/rendition.rs). Plays to 8 s, seeks to 13 s, and
// prints what the video element and Shaka said; a Shaka error is an exit
// status of 1.
//
//   npm install && node drive.mjs <playlist url> [start seconds] [shaka version]
//
// Needs Chrome (CHROME, else /usr/bin/google-chrome) and the network for
// Shaka itself.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import puppeteer from 'puppeteer-core';

const [url, start, shaka] = process.argv.slice(2);
const here = path.dirname(new URL(import.meta.url).pathname);
const server = http
  .createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(fs.readFileSync(path.join(here, 'page.html')));
  })
  .listen(0, '127.0.0.1');
await new Promise((resolve) => server.on('listening', resolve));
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME || '/usr/bin/google-chrome',
  headless: true,
  args: ['--autoplay-policy=no-user-gesture-required'],
});
const page = await browser.newPage();
const query = shaka ? `?shaka=${shaka}` : '';
await page.goto(`http://127.0.0.1:${server.address().port}/page.html${query}`);
await page.evaluate(
  (u, s) => {
    run(u, s).catch((e) => window.result.events.push('run threw ' + e));
  },
  url,
  start ? Number(start) : undefined,
);
const sample = () =>
  page.evaluate(() => {
    const v = document.getElementById('v');
    const quality = v.getVideoPlaybackQuality();
    return {
      time: v.currentTime,
      buffered: [...Array(v.buffered.length).keys()].map((i) => [v.buffered.start(i), v.buffered.end(i)]),
      frames: quality.totalVideoFrames,
      dropped: quality.droppedVideoFrames,
      audioBytes: v.webkitAudioDecodedByteCount,
      events: window.result.events,
      tracks: window.result.tracks,
    };
  });
const failed = (s) => s.events.some((e) => /error|failed|threw/.test(e));
async function until(time) {
  for (let i = 0; i < 40; i++) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    const s = await sample();
    if (s.time > time || failed(s)) return s;
  }
  return sample();
}
const played = await until(8);
console.log('played', JSON.stringify(played));
await page.evaluate(() => {
  document.getElementById('v').currentTime = 13;
});
const sought = await until(15);
console.log('after a seek to 13 s', JSON.stringify(sought));
await browser.close();
server.close();
process.exit(failed(sought) || sought.time <= 13 ? 1 : 0);
