# media_kit 1.2.6, patched

This is `media_kit` 1.2.6 from pub.dev (`lib/`, `assets/`, the pubspec,
licence, README and changelog; its tests, example and screenshots left
out), wired in through `dependency_overrides` in the app's `pubspec.yaml`.
One change, in `lib/src/player/native/player/real.dart`, written to be sent
upstream as it stands.

## Custom stream_cb schemes bypass the playlist file

**What.** `NativePlayer.streamCallbackSchemes`, a static set of URI schemes
an application registered with libmpv's `mpv_stream_cb_add_ro`. A `Media`
whose URI has one of those schemes takes the branch `open` already has for
`fd://`: each item is sent as its own `loadfile ... append`, instead of all
of them being written to a temporary playlist file for `loadlist`.

**Why.** `Player.open` loads through a playlist file, and mpv opens a
`stream_cb` stream with `STREAM_ORIGIN_UNSAFE`, which it refuses to open
from a playlist (`Refusing to load potentially unsafe URL from a
playlist.`, surfaced as `No protocol handler found to open URL`). That is
the same refusal media_kit already works around for `fd://` on Android. The
alternative, `load-unsafe-playlists=yes`, is global: it would let any
playlist name `fd://` or `lavf://`, an addon's m3u included.

**Who uses it.** Xtremio plays a torrent as `xtremio://<id>` through a
protocol its Rust crate registers on each player's handle
(`rust/src/mpv_stream.rs`); `MediaKitEngine.registerMediaIdProtocolOn`
(`lib/features/player/playback_engine.dart`) adds the scheme to the set.
`test/core/media_id_playback_test.dart` plays one through a real libmpv and
fails without this change.

```diff
-      if (playlist.any((media) => media.uri.startsWith('fd://'))) {
+      if (playlist.any((media) => media.uri.startsWith('fd://') || _isStreamCallbackUri(media.uri))) {
         // The fd:// scheme is used to reference content:// URIs on Android.
         // The loadlist command does not support this by default, yielding "Refusing to load potentially unsafe URL from a playlist."
         // So, we fallback to loading each file individually.
+        // A custom protocol registered with mpv_stream_cb_add_ro is refused from a playlist the same way, so it takes this branch too.
@@
+  /// URI schemes an application registered with libmpv's `mpv_stream_cb_add_ro` on its players' handles.
+  ///
+  /// mpv opens such a stream with `STREAM_ORIGIN_UNSAFE`, so it refuses one named in the playlist file [open] writes ("Refusing to load potentially unsafe URL from a playlist"), exactly as it refuses `fd://`.
+  /// A [Media] whose scheme is in this set is therefore loaded with its own `loadfile`, as `fd://` is.
+  /// The application adds its scheme after registering the protocol; nothing else reads this.
+  static final Set<String> streamCallbackSchemes = <String>{};
+
+  static bool _isStreamCallbackUri(String uri) {
+    final colon = uri.indexOf('://');
+    return colon > 0 && streamCallbackSchemes.contains(uri.substring(0, colon).toLowerCase());
+  }
```

Upgrading media_kit means taking the new release's `lib/` and re-applying
this diff, or dropping the override once upstream carries an equivalent.
