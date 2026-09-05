# Installing an addon from the web (`stremio://` links)

What a `stremio://` link may and may not do, and how the scheme is
registered on each platform. What the app *is* is in the
[README](../README.md); which addons are worth keeping is in
[docs/ADDONS.md](ADDONS.md).

Addon directories — [stremio-addons.net](https://stremio-addons.net) above
all — install an addon by taking its own manifest URL and swapping the
scheme: `https://host/manifest.json` becomes `stremio://host/manifest.json`,
handed to the OS as a link. Xtremio registers that scheme and treats such a
link as **one thing only: open this addon's details screen**.

The contract, in full:

- **The URL is passed to the engine unmodified.** stremio-core's
  `AddonDetails` does the `stremio://` → `https://` rewrite itself, on the
  whole URL string, so a port, a path segment carrying a configuration and a
  query all survive. The app never reconstructs the URL (stremio-web does,
  and drops the port and the query doing it).
- **A link never installs anything.** It lands on the details screen with the
  manifest fetched and the Install button waiting. Visiting a page cannot add
  an addon; a press does. There is no code path from a link to `InstallAddon`,
  and a test pins that.
- **A link replaces a details screen already open** rather than stacking a
  second one, because `addon_details` is one field holding one addon, and
  does nothing at all when that screen is already showing that addon.
- **A host-less link (`stremio:///addons`) is dropped** with a log line that
  does not include the URL — a manifest URL can carry a debrid API key. Those
  are the official clients' own in-app routes, not manifest URLs.

The pieces: `lib/shell/deep_link.dart` (the source, over
[`app_links`](https://pub.dev/packages/app_links), and
`deepLinkAddonManifestUrl`, which decides what a link means), the listener in
`XtremioApp` next to the lifecycle one, and the app's `navigatorKey` — a link
arrives from the platform with no `BuildContext` to navigate with.

Registration, per platform:

| Platform | How | State |
|---|---|---|
| **Android** | `VIEW`/`BROWSABLE` intent-filter with `<data android:scheme="stremio"/>` on the already-`singleTop` `MainActivity` | Wired |
| **iOS / macOS** | `CFBundleURLTypes` in `Runner/Info.plist` | Wired (unbuilt here — no Mac) |
| **Linux** | `linux/com.zond.xtremio.desktop` (`MimeType=x-scheme-handler/stremio;`, `Exec=xtremio %u`) plus a runner that is a single instance handling its own command line | Wired; the .desktop file must be installed by hand or by a package (see the file) |
| **Windows** | A `HKCU\Software\Classes\stremio` URL-protocol key, which only an installer can write | **Not wired** — there is no installer in this repo |

The Linux path is the one that was exercised end to end: with the app
running, `./build/linux/x64/debug/bundle/xtremio
"stremio://v3-cinemeta.strem.io/manifest.json"` exits immediately without
starting a second copy, and the running instance pushes the addon-details
route (a second, different link replaces it). Android was not run against a
device here; the `adb` line for it is in [ANDROID.md](../ANDROID.md).

No App Links / Universal Links verification is possible for any of these: the
host in a `stremio://` URL is the *addon's* domain, which could be anyone's,
so there is no domain this app could claim with an `assetlinks.json` or an
`apple-app-site-association`. A custom scheme is all this can be, which is
what the official Stremio clients register too.

**On a television**, where a remote cannot work a browser, the route is the
other one on the Addons screen: install the addon on the website *into your
Stremio account* from a phone or a laptop, then press "Refresh addons from
account" (`PullAddonsFromAPI`) on the TV.
