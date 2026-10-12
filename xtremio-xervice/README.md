# xtremio-xervice

This service pairs a television with files in a Google Drive, over a QR
code. Beside that it serves the manifest that Drive plays are tracked
under, the "More like this" answers ([below](#more-like-this)), a title's
scores ([Ratings](#ratings)) and what is kept for a signed-in account
([Your account](#your-account)). It is served at
`https://xtremio-xervice.web.app`.

The television cannot run the Google Picker, which is web-only. Nor can it
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

A television draws the QR for step 2, and a phone opens that link itself.
That is the only place the two shapes differ, and the one thing the
service is told about it (see *Two shapes* below).

Nothing of a pairing is stored long-term. A refresh token lives here for
the minutes between a phone signing in and a television collecting it.

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
else is `tv`). That is the only thing this service knows about which kind
of device asked.

A television's viewer looks up at the screen, so the pick page ends with
"on the way to your television" and stops. A phone's viewer was handed to a
browser *by the app on the same phone*, and stopping there leaves them in a
browser with nothing to do. So for those sessions the page navigates to
`stremio:///pair` when the picking is done, which brings the app back to the
front.

The app **does not act on that link**. It already drops a `stremio://`
link with no host (those are the official Stremio clients' own in-app
routes). So the scheme gains no second meaning, and a launch link the
platform replays on a cold start days later is dropped then too. The whole
effect is the platform switching tasks. The URL is this service's constant
(`HAND_BACK_LINK`) and never the app's to send, because a page on this
origin navigating to a client-supplied URL, with a signed-in viewer in front
of it, is an open redirect.

Only a build that asked for the hand-back ever sends `phone`. That is what
makes it safe to navigate to a custom scheme: the app that asked is the app
on the device. The confirmation is drawn and a **Back to Xtremio** button shown
before the navigation is attempted, so a browser that refuses to follow a
custom scheme without a tap leaves a page that says what happened and offers
the tap.

## The addon manifest, which offers nothing

`/manifest.json` is a Stremio addon manifest (`public/manifest.json`)
declaring `stream` for `movie` and `series` ids, and every `/stream/**` is
rewritten to one static `public/no-streams.json`, `{"streams":[]}`, cached
for a day. No function runs for either.

It exists for the app's Drive plays. stremio-core keeps a play's progress
(the resume position, the watched mark, Continue Watching, the up-next)
only when the player was loaded with a stream request. That request names
the addon the stream came from. A Drive file came from this service, so the app names
this manifest (`driveStreamRequest` in `lib/core/drive_playback.dart`)
rather than borrowing an installed addon that never offered the file. The
core then asks it for the next episode's streams like any addon, and gets
the static empty answer. The app finds the next episode's Drive file
itself. It is not meant to be installed, and installing it adds
nothing.

## More like this

`GET /similar/{type}/{id}` (a Cinemeta id, `movie` or `series`) answers
`{"titles": [{title, year, kind, why}, …], "version": 1, "model": "…"}`:
what a model suggests watching after that title. It is its own function (`functions/similar.js`) with its
own secret, `GEMINI_API_KEY`, so a Gemini outage cannot touch pairing. The
question is built here from Cinemeta's name and year for the id, so nobody
can put their own text through the key. The first answer for a title is
stored in Firestore under the title and `QUESTION_VERSION` and served to
everyone after: one model call per title, ever, until the question
changes. There is no "ask again". `tool/recommendations/README.md` says
how the model and the wording were chosen.

**Changing the model** is: change `MODEL` in `functions/similar.js`, deploy,
done. Every stored answer names the model that gave it. A read that finds
another model's answer serves it at once and queues the title
(`similarRevalidate/{doc id}`), and that is all the request does. A
scheduled function, `similarRevalidate` (every ten minutes, europe-west1,
the same `GEMINI_API_KEY`), takes up to fourteen queued titles a pass,
oldest first, claims each as a first ask does, asks the new model and
replaces the stored answer when it lands. A failed re-ask leaves the old
answer, and the title stays queued for three passes. The re-ask is not work
after the response: on 2nd-gen functions that runs with the CPU throttled
once the response is flushed, and can be stopped at any moment. At most
2000 re-asks a day are spent (`REASK_CAP`, counted in
`similarReasks/{day}`). 144 passes of 14 is 2016, so the counter is what
holds it. A switch therefore trickles through the titles people actually
open rather than spiking the bill. Past the cap the queue waits for the
next day. `QUESTION_VERSION` is bumped only
for a changed question or answer schema, and that re-asks every title at
once.

The edge keeps a current answer a day and serves it for a week beyond that
while it fetches a fresh copy (`stale-while-revalidate`), so a replaced
answer reaches the edge within a day. An answer from another model is kept
ten minutes, so the replacement is picked up soon after it lands.

## Ratings

`GET /ratings/{type}/{id}` (a Cinemeta id, `movie` or `series`) answers a
title's scores from [MDBList](https://mdblist.com):

```json
{"imdb": {"score": 8.1, "votes": 673852}, "tmdb": {"score": 7.6, "votes": 10114},
 "tomatoes": {"score": 97, "votes": 102}, "popcorn": {"score": 90},
 "fetchedAt": "2026-10-03T12:00:00.000Z"}
```

IMDb and TMDB are out of ten. The Tomatometer (`tomatoes`) and the
Popcornmeter (`popcorn`) are percentages. A source with no score is `null`,
and `votes` is there only where MDBList states it. It is its own function (`functions/ratings.js`) with
its own secret, `MDBLIST_API_KEY`. The MDBList URL is built from the type
(`movie` → `movie`, `series` → `show`) and an id that must match
`tt` and digits, so nothing else can be asked through the key.

The answer is stored in Firestore (`ratings/{type}_{id}`) and served for
seven days, or one day when MDBList had no score at all. The edge keeps it
a day. MDBList's free tier is a daily request count. A `429` writes the
reset it names to `ratings/_limit`, and no title is fetched again until
then. Any other failure holds that title back an hour. Either way the
answer is the stored one however old, or else every score `null` with
`fetchedAt: null`, kept at the edge ten minutes. It is never an error
status and never a retry.
Two first requests for a title pay for one fetch. The key travels in the
query string, so neither the URL nor a fetch error's text is ever logged.

Tests: `cd functions && npm test` (Node's own runner; no install needed).

## Your account

`POST /identity` takes `{"authKey": "…"}`, the session key of a device
signed in to Stremio. It answers `{"token": "…", "expiresAt": "…"}`: a
token of this service's own, good for an hour, naming the account's
Stremio user id. The routes that keep something for an account take it as
`Authorization: Bearer …`. A missing, forged or expired one is `401`, and
renewing is the same call again. It is its own function
(`functions/account.js`) with its own secret, `IDENTITY_KEY`, which signs
the tokens (HMAC-SHA256). A token carries its own expiry, so nothing about
a session is stored.

The function asks Stremio whose key it is, with the request stremio-core
itself sends: `POST https://api.strem.io/api/getUser` with
`{"type": "GetUser", "authKey"}`. It reads one field of the answer, the
user's `_id`. **The auth key passes through here once per
token, to prove who you are, and is not kept**: not stored, not logged,
not in the token. Nor is the e-mail Stremio answers with. A log line names
an account by the first twelve hex of its id's SHA-256 at most.

**Faces.** `GET /faces` answers what the account has said about titles,
`{"faces": {"<title id>": {"kind": "like" | "dislike" | "dismissed" |
"none", "at": <ms>}}, "clearedAt": <ms>}`. `PUT /faces` with the same
shape merges what a device sent into it and answers the result: newest per
title wins, and a title only one side has is kept. `DELETE /faces` empties
it and stamps `clearedAt`. No mark at or before that time is taken from
any device afterwards. The marks are kept in `faces/{user id}`, at most
five thousand. **Likes are stored under the Stremio user id in the
clear.** They are title ids and times and nothing else, and the app's
Settings deletes them.

**The Drive vault.** `PUT /vault/drive` with `{"refreshToken": "…"}` keeps
the account's Google Drive grant, the latest pairing's, and answers
`{"storedAt"}`. `GET /vault/drive` answers `{"refreshToken", "storedAt"}`
or `404`. `DELETE /vault/drive` forgets it. It is kept in `vault/{user id}`
**encrypted at rest**: AES-256-GCM under the `GRANT_KEY` secret, a random
IV per write, the user id as additional data so a sealed grant opens only
under its own account. The function opens it only to hand it to a device
holding a live token for that account, and never logs it. Revoking the
grant itself is Google's: myaccount.google.com/permissions.

**The trust statement.** The Stremio auth key transits xervice once to
prove who you are, and is not kept. Your likes are stored under your
Stremio user id in the clear, and your Drive grants encrypted at rest.
Delete them any time from Settings (the app's Settings -> Account has "Forget my
likes everywhere" and "Forget my Drive grants everywhere").

`/identity` is limited to thirty calls an hour per calling address (the
first address of `X-Forwarded-For`, which Hosting puts the caller in), and
every route behind a token to six hundred an hour per account, in the same
`rate` collection as the pairing limits.

## Why there is no App Check

App Check attests that a request came from a build Google Play
distributed. Every install of this app is sideloaded, from Drive or from a
GitHub release. So App Check would reject every real user while stopping
nobody. `/refresh` is useless without a refresh token this OAuth client
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
firebase functions:secrets:set MDBLIST_API_KEY        # for /ratings
# Signs the /identity tokens. Paste 32 random bytes, base64, at the prompt
# (`openssl rand -base64 32`). Changing it refuses every token out until
# the device renews it, which it does by itself on the refusal.
firebase functions:secrets:set IDENTITY_KEY           # for /identity
# Seals the Drive vault: 32 random bytes, base64, the same way. Keep it:
# a new one cannot open what the old one sealed, and every account's
# vault reads as unreadable until its next pairing writes it again.
firebase functions:secrets:set GRANT_KEY              # for /vault/drive

# The pages carry two public values; neither is a secret.
sed -i "s/__CLIENT_ID__/<the web client id>/" public/link.html
sed -i "s/__API_KEY__/<the browser api key>/;s/__APP_ID__/<the project number>/" public/pick.html
```

Then deploy. The scheduled `similarRevalidate` runs on Cloud Scheduler.
The CLI enables the Cloud Scheduler API on the first deploy of a scheduled
function, given an account that may enable APIs. Otherwise run
`gcloud services enable cloudscheduler.googleapis.com --project=xtremio-xervice`
first:

```sh
cd functions && npm install && cd ..
firebase deploy --only functions,hosting,firestore:rules
```

The `npm install` is not optional, and its absence does not say so.
Without `functions/node_modules` the CLI warns once, in passing, that it
"couldn't find firebase-functions package", and then fails with
`Error: An unexpected error has occurred`. **Hosting does not go out
either**, so the pages stay on the last deployed version while the command
looks like it ran.
`node_modules/` is not in the repo, so a fresh clone needs this. Check a
deploy by fetching something you changed (`curl -s
https://xtremio-xervice.web.app/pick | grep ...`) rather than by its exit
code, which a pipe to `tail` will hand you as 0.

Finally, set a **TTL policy** on Firestore so abandoned sessions clean
themselves up. The field is `expiresAt`, on both `sessions` and `rate`:

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
server needs. stream-server's `docs/design/translated-sources.md`
specifies `DriveSource` as "a `ProxySource` with a header supplier that
refreshes", and the header supplier is `POST /refresh`.

## The question this proof no longer turns on

**Does picking a *folder* grant `drive.file` access to what is inside
it?** Google's documentation does not say: the scopes guide, the Picker
overview and the folders guide are silent on it. Multiselect already
covers picking more than one file at a time, so the folder question does
not block anything. It is worth an answer, but nothing depends on it. The
Picker still allows a folder to be selected, so the answer can be had by
hand. Pick a folder rather than a file, then run

```sh
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://www.googleapis.com/drive/v3/files?q='$FILE'+in+parents&fields=files(id,name)"
```

An empty list means folders buy nothing, and a folder picked by mistake is
one row in the app's list that will not play. A list of the folder's videos
means a viewer can pair once per folder without naming the episodes. Then
the second question is worth asking: whether a file *added later* is
included too, the only thing multiselect cannot do.

## What is deliberately not here

* **No pairing's token on this server after pickup.** The session is
  deleted in the same request that hands it over. The one refresh token
  kept is the one a signed-in device chose to put in its account's vault
  ([Your account](#your-account)), sealed under `GRANT_KEY`.
* **No client-side Firestore access.** The rules deny everything; only
  the function, running as admin, touches it.
* **No App Check**, for the reason above.
* **No production hardening**: no structured logging, no alerting, no
  budget cap. Set a budget alert on the project before pointing anything
  at this.
