# drive-link

Pairing a television with one Google Drive file, over a QR code.

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
| 1 | television | `POST /session` → a session, a QR link, a typeable code |
| 2 | phone | opens `/link?s=…`, signs in with `drive.file` |
| 3 | here | `/oauth/callback` exchanges the code, keeps the tokens on the session |
| 4 | phone | `/pick?s=…` draws the Picker; the viewer chooses a file |
| 5 | television | `GET /session/{id}` collects, **once** — the session is then deleted |
| 6 | television | `POST /refresh` when the access token ages out mid-film |

Nothing is stored long-term. A refresh token lives here for the minutes
between a phone signing in and a television collecting it.

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
   https://xtremio-drive.web.app/oauth/callback
   https://xtremio-drive.firebaseapp.com/oauth/callback
   http://localhost:5000/oauth/callback
   ```
   JavaScript origins: the same three, without the path.
3. **Browser API key**, restricted by HTTP referrer to
   `https://xtremio-drive.web.app/*`. This is the Picker's
   `developerKey`.
4. **OAuth consent screen**: External, and **published to Production**.
   In Testing, Google expires refresh tokens after seven days, which
   looks exactly like a bug a fortnight later. Only `drive.file` is
   requested, which is non-sensitive, so there is no verification to sit
   through.

Then the secrets and the two values the pages need:

```sh
firebase use xtremio-drive
firebase functions:secrets:set OAUTH_CLIENT_ID        # the web client id
firebase functions:secrets:set OAUTH_CLIENT_SECRET    # its secret

# The pages carry two public values; neither is a secret.
sed -i "s/__CLIENT_ID__/<the web client id>/" public/link.html
sed -i "s/__API_KEY__/<the browser api key>/;s/__APP_ID__/<the project number>/" public/pick.html
```

Deploy:

```sh
cd functions && npm install && cd ..
firebase deploy --only functions,hosting,firestore:rules
```

Finally, a **TTL policy** on Firestore so abandoned sessions clean
themselves up — field `expiresAt` on both `sessions` and `rate`:

```sh
gcloud firestore fields ttls update expiresAt \
  --collection-group=sessions --enable-ttl --project=xtremio-drive
gcloud firestore fields ttls update expiresAt \
  --collection-group=rate --enable-ttl --project=xtremio-drive
```

## Proving it works, without the app

The whole point of the proof is the last step. No television needed:

```sh
HOST=https://xtremio-drive.web.app

# 1. Stand in for the television.
curl -s -X POST $HOST/session | tee /tmp/s.json
# open the `link` from that on a phone, sign in, pick a video

# 2. Collect, as the television would. This deletes the session.
ID=$(python3 -c "import json;print(json.load(open('/tmp/s.json'))['sessionId'])")
curl -s $HOST/session/$ID | tee /tmp/t.json

# 3. The proof: one kilobyte, from the middle of the viewer's file.
TOKEN=$(python3 -c "import json;print(json.load(open('/tmp/t.json'))['accessToken'])")
FILE=$(python3 -c "import json;print(json.load(open('/tmp/t.json'))['file']['fileId'])")
curl -s -D- -o /tmp/chunk.bin \
  -H "Authorization: Bearer $TOKEN" -H "Range: bytes=1048576-1049599" \
  "https://www.googleapis.com/drive/v3/files/$FILE?alt=media" | head -20
ls -l /tmp/chunk.bin        # expect 1024 bytes, and a 206 above
```

A `206 Partial Content` and exactly 1024 bytes is the answer: this flow
can serve byte ranges out of a viewer's Drive, which is all the streaming
server needs (`docs/translated-sources.md` specifies `DriveSource` as "a
`ProxySource` with a header supplier that refreshes" — the header
supplier is `POST /refresh`).

## The question this proof should also answer

**Does picking a *folder* grant `drive.file` access to what is inside
it?** Google's documentation does not say — the scopes guide, the Picker
overview and the folders guide were all checked and none of them
addresses it. It decides whether this is ever more than one file at a
time, so answer it by hand in the same session: pick a folder rather than
a file, then

```sh
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://www.googleapis.com/drive/v3/files?q='$FILE'+in+parents&fields=files(id,name)"
```

An empty list means folders buy nothing and the design stays one file per
pairing. A list of the folder's videos means a viewer can pair once per
folder — and then it is worth asking the second question, whether a file
*added later* is included too.

## What is deliberately not here

* **No token on this server after pickup.** The session is deleted in the
  same request that hands it over.
* **No client-side Firestore access.** The rules deny everything; only
  the function, running as admin, touches it.
* **No App Check**, for the reason above.
* **No production hardening**: no structured logging, no alerting, no
  budget cap. Set a budget alert on the project before pointing anything
  at this.
