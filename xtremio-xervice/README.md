# xtremio-xervice

Pairing a television with files in a Google Drive, over a QR code -- and,
beside it, the manifest that Drive plays are tracked under and the "More
like this" answers ([below](#more-like-this)). Served at
`https://xtremio-xervice.web.app`.

The television cannot run the Google Picker — it is web-only — and cannot
hold an OAuth client secret, because it is an app anybody can unpack. So
the phone does the picking, and this service does the two things that
need the secret: turning an authorization code into tokens, and turning a
refresh token into an access token.

**This is a proof of concept.** What it is proving is one thing: that
this flow can produce a *working ranged read* of a file in somebody's
Drive. Everything the app needs after that is the same call, repeated.

## The flow

| step | who | what |
|---|---|---|
| 1 | app | `POST /session` → a session and the link a QR carries |
| 2 | phone | opens `/link?s=…`, signs in with `drive.file` |
| 3 | here | `/oauth/callback` exchanges the code, keeps the tokens on the session |
| 4 | phone | `/pick?s=…` draws the Picker; the viewer chooses **one file or several** |
| 5 | app | `GET /session/{id}` collects, **once** — the session is then deleted |
| 6 | app | `POST /refresh` when the access token ages out mid-film |

A television draws the QR for step 2 and a phone opens that link itself,
which is the only place the two shapes differ — and the one thing the
service is told about it. See *Two shapes* below.

Nothing of a pairing is stored long-term. A refresh token lives here for the minutes
between a phone signing in and a television collecting it.

## What a session carries

`GET /session/{id}` answers a `ready` session with the tokens and the
files:

```json
{
  "status": "ready",
  "refreshToken": "…",
  "accessToken": "…",
  "accessExpiresAt": "2026-09-25T21:00:00.000Z",
  "files": [
    {"fileId": "…", "name": "S01E01.mkv", "mimeType": "video/x-matroska"},
    {"fileId": "…", "name": "S01E02.mkv", "mimeType": "video/x-matroska"}
  ]
}
```

`files` is the list, in the order the viewer picked them.

## Two shapes, and the hand-back

`POST /session` takes `{"shape": "tv" | "phone" | "desktop"}` (anything
else is `tv`), and that is the only thing this service knows about which
kind of device asked.

A television's viewer looks up at the screen, so the pick page ends with
"on the way to your television" and stops. A phone's viewer was handed to a
browser *by the app on the same phone*, and stopping there leaves them in a
browser with nothing to do — so for those sessions the page navigates to
`stremio:///pair` when the picking is done, which brings the app back to the
front.

The app **does not act on that link**. A `stremio://` link with no host is
the shape it already drops (those are the official Stremio clients' own
in-app routes), so the scheme gains no second meaning, and a launch link the
platform replays on a cold start days later is dropped then too. The whole
effect is the platform switching tasks. The URL is this service's constant
(`HAND_BACK_LINK`) and never the app's to send, because a page on this
origin navigating to a client-supplied URL, with a signed-in viewer in front
of it, is an open redirect.

`phone` is only ever sent by a build that asked for the hand-back, which is what makes
it safe to navigate to a custom scheme: the app that asked is the app on the
device. The confirmation is drawn and a **Back to Xtremio** button shown
before the navigation is attempted, so a browser that refuses to follow a
custom scheme without a tap leaves a page that says what happened and offers
the tap.

## The addon manifest, which offers nothing

`/manifest.json` is a Stremio addon manifest (`public/manifest.json`)
declaring `stream` for `movie` and `series` ids, and every `/stream/**` is
rewritten to one static `public/no-streams.json`, `{"streams":[]}`, cached
for a day. No function runs for either.

It exists for the app's Drive plays. stremio-core keeps a play's progress --
the resume position, the watched mark, Continue Watching, the up-next --
only when the player was loaded with a stream request, which names the addon
the stream came from. A Drive file came from this service, so the app names
this manifest (`driveStreamRequest` in `lib/core/drive_playback.dart`)
rather than borrowing an installed addon that never offered the file. The
core then asks it for the next episode's streams like any addon; the static
empty answer is what it gets, and the app finds the next episode's Drive
file itself. It is not meant to be installed, and installing it adds
nothing.

## More like this

`GET /similar/{type}/{id}` (a Cinemeta id, `movie` or `series`) answers
`{"titles": [{title, year, kind, why}, …]}`: what a model suggests watching
after that title. It is its own function (`functions/similar.js`) with its
own secret, `GEMINI_API_KEY`, so a Gemini outage cannot touch pairing. The
question is built here from Cinemeta's name and year for the id, so nobody
can put their own text through the key, and the first answer for a title is
stored in Firestore under the title and `QUESTION_VERSION` and served to
everyone after -- one model call per title, ever, until the question
changes. There is no "ask again". How the model and the wording were chosen
is `tool/recommendations/README.md`.

## Why there is no App Check

App Check attests that a request came from a build Google Play
distributed. Every install of this app is sideloaded — from Drive, or
from a GitHub release — so it would reject every real user while stopping
nobody: `/refresh` is useless without a refresh token this OAuth client
issued, and the only way to hold one is to have completed this flow with
your own Google account. What is left to defend against is **cost**, and
that is what the per-hour rate limits are for.

## Setting it up

The console work, once:

1. **APIs** — enable *Google Drive API* and *Google Picker API*. The
   second is easy to miss; the Picker will not load without it.
2. **OAuth client**, type *Web application*. Redirect URIs:
   ```
   https://xtremio-xervice.web.app/oauth/callback
   https://xtremio-xervice.firebaseapp.com/oauth/callback
   http://localhost:5000/oauth/callback
   ```
   JavaScript origins: the same three, without the path.
3. **Browser API key**, restricted by HTTP referrer to
   `https://xtremio-xervice.web.app/*`. This is the Picker's
   `developerKey`.
4. **OAuth consent screen**: External, and **published to Production**.
   In Testing, Google expires refresh tokens after seven days, which
   looks exactly like a bug a fortnight later. Only `drive.file` is
   requested, which is non-sensitive, so there is no verification to sit
   through.

Then the secrets and the two values the pages need:

```sh
firebase use xtremio-xervice
firebase functions:secrets:set OAUTH_CLIENT_ID        # the web client id
firebase functions:secrets:set OAUTH_CLIENT_SECRET    # its secret
firebase functions:secrets:set GEMINI_API_KEY         # for /similar

# The pages carry two public values; neither is a secret.
sed -i "s/__CLIENT_ID__/<the web client id>/" public/link.html
sed -i "s/__API_KEY__/<the browser api key>/;s/__APP_ID__/<the project number>/" public/pick.html
```

Deploy:

```sh
cd functions && npm install && cd ..
firebase deploy --only functions,hosting,firestore:rules
```

The `npm install` is not optional and its absence does not say so: without
`functions/node_modules` the CLI warns once, in passing, that it "couldn't
find firebase-functions package" and then fails with `Error: An unexpected
error has occurred` — and **hosting does not go out either**, so the pages
stay on the last deployed version while the command looks like it ran.
`node_modules/` is not in the repo, so a fresh clone needs this. Check a
deploy by fetching something you changed (`curl -s
https://xtremio-xervice.web.app/pick | grep ...`) rather than by its exit
code, which a pipe to `tail` will hand you as 0.

Finally, a **TTL policy** on Firestore so abandoned sessions clean
themselves up — field `expiresAt` on both `sessions` and `rate`:

```sh
gcloud firestore fields ttls update expiresAt \
  --collection-group=sessions --enable-ttl --project=xtremio-xervice
gcloud firestore fields ttls update expiresAt \
  --collection-group=rate --enable-ttl --project=xtremio-xervice
```

## Proving it works, without the app

The whole point of the proof is the last step. No television needed:

```sh
HOST=https://xtremio-xervice.web.app

# 1. Stand in for the television. (A phone pairing sends
#    -H 'Content-Type: application/json' -d '{"shape":"phone"}' instead.)
curl -s -X POST $HOST/session | tee /tmp/s.json
# open the `link` from that on a phone, sign in, pick one video or several

# 2. Collect, as the television would. This deletes the session.
ID=$(python3 -c "import json;print(json.load(open('/tmp/s.json'))['sessionId'])")
curl -s $HOST/session/$ID | tee /tmp/t.json

# 3. The proof: one kilobyte, from the middle of the first file picked.
TOKEN=$(python3 -c "import json;print(json.load(open('/tmp/t.json'))['accessToken'])")
FILE=$(python3 -c "import json;print(json.load(open('/tmp/t.json'))['files'][0]['fileId'])")
curl -s -D- -o /tmp/chunk.bin \
  -H "Authorization: Bearer $TOKEN" -H "Range: bytes=1048576-1049599" \
  "https://www.googleapis.com/drive/v3/files/$FILE?alt=media" | head -20
ls -l /tmp/chunk.bin        # expect 1024 bytes, and a 206 above
```

A `206 Partial Content` and exactly 1024 bytes is the answer: this flow
can serve byte ranges out of a viewer's Drive, which is all the streaming
server needs (stream-server's `docs/design/translated-sources.md`
specifies `DriveSource` as "a `ProxySource` with a header supplier that
refreshes" — the header supplier is `POST /refresh`).

## The question this proof no longer turns on

**Does picking a *folder* grant `drive.file` access to what is inside
it?** Google's documentation does not say — the scopes guide, the Picker
overview and the folders guide were all checked and none of them
addresses it. It used to decide whether this could ever be more than one
file at a time; multiselect decides that now, and the answer is yes. So the
folder question is worth an answer but no longer blocks anything, and the
Picker still allows a folder to be selected so that it can be had by hand:
pick a folder rather than a file, then

```sh
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://www.googleapis.com/drive/v3/files?q='$FILE'+in+parents&fields=files(id,name)"
```

An empty list means folders buy nothing, and a folder picked by mistake is
one row in the app's list that will not play. A list of the folder's videos
means a viewer can pair once per folder without naming the episodes — and
then it is worth asking the second question, whether a file *added later* is
included too, which is the only thing multiselect cannot do.

## What is deliberately not here

* **No token on this server after pickup.** The session is deleted in the
  same request that hands it over.
* **No client-side Firestore access.** The rules deny everything; only
  the function, running as admin, touches it.
* **No App Check**, for the reason above.
* **No production hardening**: no structured logging, no alerting, no
  budget cap. Set a budget alert on the project before pointing anything
  at this.
