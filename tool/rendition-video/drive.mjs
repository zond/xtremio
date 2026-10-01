// Plays a rendition's stream the way the Cast receiver plays a file: a plain
// `<video src>` in Chrome, headless -- not Media Source, which zond's
// Chromecast with Google TV cannot do above 720p (stream-server
// docs/design/renditions.md, F2). Point it at a stream a server is serving,
// e.g. the one `cargo test --test rendition serve -- --ignored` writes
// (rust/tests/rendition.rs). Plays for 8 s and prints, every second, the
// position, what is buffered, what was decoded and the error if any; exits
// 1 on a media error or a position that never moved.
//
//   npm install && node drive.mjs <stream url>
//
// Needs Chrome: CHROME, else /usr/bin/google-chrome.
import http from 'node:http';
import puppeteer from 'puppeteer-core';

const [url] = process.argv.slice(2);
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
      audioBytes: v.webkitAudioDecodedByteCount,
      error: v.error && `${v.error.code} ${v.error.message}`,
    };
  });
let first;
let last;
for (let i = 0; i < 8; i++) {
  await new Promise((resolve) => setTimeout(resolve, 1000));
  last = await sample();
  first ??= last;
  console.log(JSON.stringify(last));
  if (last.error) break;
}
await browser.close();
server.close();
process.exit(last.error || last.time <= first.time ? 1 : 0);
