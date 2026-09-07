package com.zond.xtremio

import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastDevice
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /**
     * The downloads foreground service's side of the conversation, alive
     * for as long as the engine is. Held so the permission answer and the
     * notification's intent can reach it, and so it can be let go of.
     */
    private var downloads: DownloadsChannel? = null

    /**
     * The `editText` call a [TextEntryActivity] is up for; at most one, and
     * answered by its result. Dropped unanswered if the activity is torn
     * down first -- the engine that asked is going with it.
     */
    private var textEntry: MethodChannel.Result? = null

    /**
     * What is telling Dart the rate this display is really refreshing at,
     * alive for as long as the engine is. Held so its `DisplayListener` can
     * be unregistered with the activity rather than outliving it.
     */
    private var displayRefreshRates: DisplayRefreshRates? = null

    /**
     * What is telling Dart whether this device's connection is billed by
     * the byte, alive for as long as the engine is. Held so its
     * `NetworkCallback` is unregistered with the activity rather than
     * outliving it.
     */
    private var networkCost: NetworkCostWatcher? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Must run before the Flutter engine starts Dart: RustLib.init() may
        // issue HTTPS requests right away.
        NativeInit.initTlsVerifier(applicationContext)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Answers `DeviceProfile.detect()` (lib/shell/device_profile.dart),
        // called once from main() before runApp. The Dart side falls back to
        // "a phone" on any error, so nothing here throws.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "profile" -> result.success(
                        mapOf("isTv" to isTv(), "hasTouch" to hasTouch()),
                    )
                    // What the Diagnostics header says this device is
                    // (lib/core/diagnostics_client.dart). Dart's own
                    // `Platform.operatingSystemVersion` is the build
                    // fingerprint here ("W1VVS36H.7-108-8-6"), which names
                    // neither the Android version nor the hardware.
                    "os" -> result.success(
                        mapOf(
                            "release" to Build.VERSION.RELEASE,
                            "sdkInt" to Build.VERSION.SDK_INT,
                            "model" to Build.MODEL,
                            "manufacturer" to Build.MANUFACTURER,
                        ),
                    )
                    // Where a receiver actually is, which is what lets the
                    // embedded server name an interface that receiver can
                    // connect back to
                    // (lib/features/cast/google_cast_client.dart).
                    "castDeviceAddress" -> result.success(
                        castDeviceAddress(call.argument<String>("id")),
                    )
                    // A string typed on a screen of the platform's own,
                    // which is the only way a remote can type at all
                    // (lib/shell/tv_text_entry.dart, TextEntryActivity.kt).
                    "editText" -> editText(call, result)
                    // What rate to present the picture at, asked for while
                    // a film is playing and given back when it stops
                    // (lib/shell/display_frame_rate.dart). The only two
                    // calls on this channel that do something rather than
                    // report something; both answer null, because what the
                    // display then does is the platform's to decide.
                    "setFrameRate" -> {
                        matchFrameRate(call.argument<Double>("fps"))
                        result.success(null)
                    }
                    "clearFrameRate" -> {
                        clearFrameRate()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // What the display is really refreshing at, which is a different
        // question from the rate asked for above and answered by a stream
        // rather than a call (lib/shell/display_frame_rate.dart).
        displayRefreshRates = DisplayRefreshRates().also {
            EventChannel(flutterEngine.dartExecutor.binaryMessenger, DISPLAY_CHANNEL)
                .setStreamHandler(it)
        }
        // Whether the connection this device is on is billed by the byte,
        // watched rather than asked (lib/shell/network_cost.dart): it
        // decides whether the embedded server may go on sharing a torrent
        // between sessions, and a phone changes networks under that
        // decision without the app being touched.
        networkCost = NetworkCostWatcher(this).also {
            EventChannel(flutterEngine.dartExecutor.binaryMessenger, NETWORK_CHANNEL)
                .setStreamHandler(it)
        }
        // The downloads notification (lib/features/downloads/downloads_service.dart).
        // A tap that launched the app is kept here rather than delivered:
        // Dart installs its handler a moment later, and a call made before
        // that would go nowhere.
        downloads = DownloadsChannel(this, flutterEngine.dartExecutor.binaryMessenger)
            .apply { pendingOpen = opensDownloads(intent) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // The notification's body, with the app already running.
        if (opensDownloads(intent)) downloads?.openRequested()
    }

    /**
     * Asks the display to present [fps] frames a second, so that a 23.976
     * fps film is not laid out on a 59.94 Hz output's 3:2 cadence -- some
     * frames shown twice, some three times, and the ones that miss their
     * vsync dropped. On the owner's projector that was 560 frames dropped
     * at the video output against none at the decoder.
     *
     * Only ever called for a television: the Dart side asks the device
     * profile first, and a phone's panel has no business switching. A rate
     * that is not a rate is ignored rather than guessed at -- asking for
     * one we do not know is worse than not asking -- and so is one outside
     * the band real content declares ([FrameRateMode.plausible]), which is
     * the *only* guard the surface path has: `Surface.setFrameRate` takes
     * whatever number it is handed and `CHANGE_FRAME_RATE_ALWAYS` lets it
     * blank the picture to honour it.
     *
     * Two paths, and the Android version chooses:
     *
     * - **Android 12 (API 31) and up** state what the content *is* and let
     *   the platform pick the mode. `FRAME_RATE_COMPATIBILITY_FIXED_SOURCE`
     *   says these frames arrive at a fixed rate, and
     *   `CHANGE_FRAME_RATE_ALWAYS` is what permits a change the panel
     *   cannot make invisibly: 59.94 Hz to 23.976 Hz retrains the HDMI
     *   link and blanks the picture for about a second, and every useful
     *   switch on a television is of that kind.
     * - **Android 11 (API 30) and below** name a mode outright through the
     *   window's `preferredDisplayModeId` ([FrameRateMode.matching] picks
     *   which). API 30 has a two-argument `setFrameRate`, but it predates
     *   `CHANGE_FRAME_RATE_ALWAYS` and so only ever switches seamlessly --
     *   which is exactly the switch a television cannot do -- so it takes
     *   the mode path with everything older.
     *
     * **The newer path is a vote, and a vote can be dropped in silence**,
     * which is what the owner's box did: `setFrameRate` returns nothing,
     * and with "Match content frame rate" unset the platform honours a
     * seamless switch only -- which 59.94 Hz to 23.976 Hz never is. So
     * what that setting says decides whether the older path follows the
     * vote ([FrameRateMode.askFor] holds the reasoning, and the reading
     * behind it), and a box that has frame rate matching turned off is
     * asked for nothing at all. With no surface to vote on there is no
     * vote to follow, and the mode is named whatever the setting says.
     */
    private fun matchFrameRate(fps: Double?) {
        if (fps == null || !FrameRateMode.plausible(fps)) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val ask = FrameRateMode.askFor(
                displayManager()?.matchContentFrameRateUserPreference
                    ?: FrameRateMode.MATCH_CONTENT_UNKNOWN,
            )
            if (ask == FrameRateAsk.NOTHING) return
            val surface = contentSurface()
            if (surface != null) {
                surface.setFrameRate(
                    fps.toFloat(),
                    Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
                    Surface.CHANGE_FRAME_RATE_ALWAYS,
                )
                if (ask == FrameRateAsk.SURFACE) return
            }
        }
        preferMode(matchingModeId(fps) ?: return)
    }

    /**
     * Gives the rate back, on every path that set one: a display left at
     * 24 Hz makes the whole system UI judder, which is a worse fault than
     * the one this fixes.
     *
     * Both paths are cleared whichever set it. Which one ran depended on
     * the Android version *and* on there being a surface to ask, so
     * clearing only the one this build would have used would leave the
     * other in force; and clearing a preference that was never set costs a
     * comparison.
     */
    private fun clearFrameRate() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            contentSurface()?.setFrameRate(
                0f,
                Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                Surface.CHANGE_FRAME_RATE_ALWAYS,
            )
        }
        preferMode(0)
    }

    /**
     * Tells Dart what this display is **really** refreshing at, once when it
     * is subscribed to and again whenever it changes.
     *
     * libmpv cannot measure this for itself here -- media_kit runs it with
     * `vo=gpu` and `gpu-context=android`, which answers `VO_NOTIMPL` to
     * `VOCTRL_GET_DISPLAY_FPS`, so the reported rate stays 0 and display
     * sync never starts (`MediaKitEngine.mpvOverrides` holds the reading).
     * It can be told, and this is where the number comes from.
     *
     * **It has to be what the display is doing, not what [matchFrameRate]
     * asked for.** Both paths above are asynchronous and neither reports
     * back: `Surface.setFrameRate` is a vote that returns nothing and can
     * be dropped in silence, `preferredDisplayModeId` is a window attribute
     * the platform acts on when it gets to it, and a set can land on a
     * neighbouring mode or refuse to move at all. Handing mpv a rate the
     * display never took would replace one wrong cadence with another and
     * hide it behind a `display-sync-active` reading `yes`. So the ask is
     * made, and then what actually happened is reported --
     * `DisplayManager.DisplayListener.onDisplayChanged` is the callback a
     * mode change arrives on.
     *
     * `Display.getRefreshRate()` and not `getMode().getRefreshRate()`,
     * which is what [asFrameRateMode] reads for the mode choosing. The
     * mode's rate is the panel's physical one; since Android 12 a frame
     * rate override can present an app at a divisor of it without changing
     * the mode at all, and `getRefreshRate()` is the one that accounts for
     * that -- the rate *this app's* frames are shown at, which is the
     * question mpv is asking. On the box this was measured on the two agree
     * (`FrameRateOverrides=none`, `frameRateOverrideConfig=Disabled`).
     *
     * The listener is registered only while Dart is subscribed, and the
     * first value is pushed at subscription because a display already on
     * the right mode fires no event and the rate would otherwise never
     * arrive at all.
     */
    private inner class DisplayRefreshRates :
        EventChannel.StreamHandler,
        DisplayManager.DisplayListener {
        private var sink: EventChannel.EventSink? = null

        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            sink = events
            displayManager()?.registerDisplayListener(this, Handler(Looper.getMainLooper()))
            emit()
        }

        override fun onCancel(arguments: Any?) = detach()

        /** Lets the display go, whether Dart cancelled or the activity did. */
        fun detach() {
            displayManager()?.unregisterDisplayListener(this)
            sink = null
        }

        override fun onDisplayAdded(displayId: Int) = Unit

        override fun onDisplayRemoved(displayId: Int) = Unit

        override fun onDisplayChanged(displayId: Int) {
            // Every display's changes arrive here; only the one this
            // activity is on says anything about the picture being watched.
            if (displayId == activityDisplay()?.displayId) emit()
        }

        private fun emit() {
            val rate = activityDisplay()?.refreshRate?.toDouble() ?: return
            // A rate that is not a rate is not reported: Dart would have to
            // refuse it anyway, and mpv reads a zero as "no display rate"
            // and silently goes back to timing against the audio clock.
            if (!rate.isFinite() || rate <= 0.0) return
            sink?.success(rate)
        }
    }

    private fun displayManager(): DisplayManager? =
        getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager

    /** The mode to ask this display for, or null for nothing to ask. */
    private fun matchingModeId(fps: Double): Int? {
        val display = activityDisplay() ?: return null
        val current = display.mode?.let(::asFrameRateMode) ?: return null
        return FrameRateMode.matching(
            fps,
            current,
            display.supportedModes.orEmpty().map(::asFrameRateMode),
        )
    }

    /** Puts [modeId] on the window, `0` being no preference at all. */
    private fun preferMode(modeId: Int) {
        val attributes = window.attributes
        if (attributes.preferredDisplayModeId == modeId) return
        attributes.preferredDisplayModeId = modeId
        window.attributes = attributes
    }

    private fun asFrameRateMode(mode: Display.Mode): FrameRateMode =
        FrameRateMode(mode.modeId, mode.physicalWidth, mode.physicalHeight, mode.refreshRate)

    @Suppress("DEPRECATION")
    private fun activityDisplay(): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else windowManager.defaultDisplay

    /**
     * The surface the app is drawn into: Flutter's own, since
     * [FlutterActivity] renders through a `SurfaceView` by default. The
     * video is a texture composited into that same surface, so its rate is
     * the surface's rate.
     *
     * Null before the view is attached, or if this ever runs against
     * Flutter's `TextureView` renderer -- both fall through to naming a
     * mode. A vote lives only as long as the surface does, so one made
     * before the window is up is not a vote at all.
     */
    private fun contentSurface(): Surface? =
        surfaceViewIn(window.decorView)?.holder?.surface?.takeIf { it.isValid }

    private fun surfaceViewIn(view: View): SurfaceView? {
        if (view is SurfaceView) return view
        if (view !is ViewGroup) return null
        for (index in 0 until view.childCount) {
            surfaceViewIn(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    /**
     * The IPv4 address the receiver with Cast device id [id] announced over
     * mDNS, or null when Android does not know one.
     *
     * `flutter_chrome_cast` maps a `CastDevice` to Dart without its address
     * (`GoogleCastClient` has the same note), but the route the Cast SDK
     * discovered still carries the device, so the address is read off that
     * -- matching on `CastDevice.getFromBundle(route.extras)?.deviceId`,
     * which is the lookup the plugin's own `selectRoute` does. Knowing
     * where the receiver is is what lets the embedded server name a local
     * interface that receiver can actually connect back to, instead of
     * ranking its own interfaces and hoping.
     *
     * `getIpAddress()` is the one read here because it answers an
     * `Inet4Address` and the server places a peer on one of its own IPv4
     * subnets. It is `@Nullable`, and it is null exactly when the receiver
     * announced no IPv4 address (`hasIPv4Address()` is what it asks), which
     * is a receiver there is nothing useful to say about anyway.
     * `getInet4Address()`, the name every older account of this gives, is
     * gone from play-services-cast 21.5.0 altogether.
     *
     * `getIpAddress()` is itself `@Deprecated` in 21.5.0, where the sibling
     * `getInetAddress()` is `@NonNull` and is not -- so the next SDK bump
     * is where this may have to move to that one and do the narrowing
     * itself, since it answers whatever the receiver announced and that can
     * be an `Inet6Address`. All of which was read off the resolved
     * artifact's own bytecode rather than off an account of it, this
     * comment having said the opposite before.
     *
     * **Nothing here throws, and there is no test to make sure of it**, so
     * it is written to have nothing to throw: every step is null-safe, and
     * the one call that can raise at all (`MediaRouter.getInstance` insists
     * on the main thread) is caught. A null answer is the answer this call
     * never having existed gives, which is what makes it safe to add.
     */
    private fun castDeviceAddress(id: String?): String? {
        if (id.isNullOrEmpty()) return null
        return try {
            MediaRouter.getInstance(this).routes
                .firstNotNullOfOrNull { route ->
                    CastDevice.getFromBundle(route.extras)?.takeIf { it.deviceId == id }
                }
                ?.ipAddress
                ?.hostAddress
        } catch (error: IllegalStateException) {
            null
        }
    }

    /**
     * Opens the text-entry screen on the value Dart is holding. A second
     * call while one is already up is answered "cancelled" rather than
     * queued: the field it came from is behind the screen that is showing.
     */
    private fun editText(call: MethodCall, result: MethodChannel.Result) {
        if (textEntry != null) {
            result.success(null)
            return
        }
        val intent = TextEntryActivity.intentFor(
            this,
            call.argument<String>("label").orEmpty(),
            call.argument<String>("value").orEmpty(),
            call.argument<String>("kind") ?: TextEntryActivity.KIND_TEXT,
        )
        textEntry = result
        try {
            startActivityForResult(intent, REQUEST_TEXT_ENTRY)
        } catch (error: ActivityNotFoundException) {
            textEntry = null
            // Never the message: it can quote the intent it was given, and
            // that intent carries a password field's value.
            result.error("text_entry_unavailable", error.javaClass.name, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_TEXT_ENTRY) return
        val pending = textEntry ?: return
        textEntry = null
        // Cancelled (Back, or the screen went away) is null, and Dart reads
        // null as "leave the value alone".
        pending.success(
            if (resultCode == RESULT_OK) {
                data?.getStringExtra(TextEntryActivity.EXTRA_VALUE)
            } else {
                null
            },
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        downloads?.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        downloads?.detach()
        downloads = null
        displayRefreshRates?.detach()
        displayRefreshRates = null
        networkCost?.detach()
        networkCost = null
        textEntry = null
        super.onDestroy()
    }

    private fun opensDownloads(intent: Intent?): Boolean =
        intent?.getBooleanExtra(DownloadsService.EXTRA_OPEN_DOWNLOADS, false) == true

    // Android TV / Google TV: the system says it is in television mode, or
    // the leanback feature is present (a TV box whose UI mode is not yet
    // reported as television at this point still has the feature).
    private fun isTv(): Boolean {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        val televisionMode =
            uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        return televisionMode || packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    private fun hasTouch(): Boolean =
        packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)

    private companion object {
        const val DEVICE_CHANNEL = "xtremio/device"
        const val DISPLAY_CHANNEL = "xtremio/display"
        const val NETWORK_CHANNEL = "xtremio/network"
        const val REQUEST_TEXT_ENTRY = 4712
    }
}
