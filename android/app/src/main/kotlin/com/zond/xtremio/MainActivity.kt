package com.zond.xtremio

import android.app.ActivityManager
import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.View
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
     * The `editText` call a [TextEntryActivity] is up for. There is at most
     * one, and its result answers it. Dropped unanswered if the activity is
     * torn down first, since the engine that asked is going with it.
     */
    private var textEntry: MethodChannel.Result? = null

    /** Typing by voice (SpeechInput.kt), alive for as long as the engine is. */
    private var speech: SpeechInput? = null

    /** The developer's codec probe (HwProbe.kt), which only the driver calls. */
    private var hwProbe: HwProbe? = null

    /** The receiver's report of the picture it shows (CastPictureChannel). */
    private var castPicture: CastPictureChannel? = null

    /**
     * The native Drive picker's side of the conversation, alive for as long
     * as the engine is. Held because its result arrives through
     * [onActivityResult], which is the activity's and not a channel's.
     */
    private var drivePicker: DrivePicker? = null

    /**
     * The videos in Android's media index, for the Library's Local list
     * (lib/features/local/android_local_media_source.dart). Held so the
     * permission answer can reach it.
     */
    private var localMedia: LocalMediaChannel? = null

    /**
     * Installing an update from the app's GitHub release
     * (lib/features/update/), alive for as long as the engine is. Held
     * because the session's status comes back through a receiver.
     */
    private var appUpdate: AppUpdateChannel? = null

    /**
     * The wake lock a cast whose picture this phone converts holds
     * (PowerChannel.kt). Held so it is let go with the activity.
     */
    private var power: PowerChannel? = null

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
                    // Which codecs the player may put on its own surface
                    // (lib/shell/video_decoders.dart, HwVideoDecoders.kt).
                    // The device's memory rides along: software decoding
                    // needs it where a hardware decoder is missing.
                    "hwVideoDecoders" -> try {
                        result.success(
                            HwVideoDecoders.onThisDevice() +
                                ("totalMemory" to totalMemoryBytes()),
                        )
                    } catch (e: RuntimeException) {
                        result.error("unavailable", e.javaClass.simpleName, null)
                    }
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
                    // The same field filled by voice, recognized in the app
                    // (lib/shell/speech_input.dart, SpeechInput.kt). What is
                    // heard comes back on the `xtremio/speech` stream.
                    "startSpeech" -> speech.let {
                        if (it == null) result.success(SpeechInput.UNAVAILABLE) else it.start(result)
                    }
                    "stopSpeech" -> {
                        speech?.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // Whether a receiver shows the picture it was handed
        // (lib/features/cast/google_cast_client.dart).
        castPicture = CastPictureChannel().also {
            EventChannel(flutterEngine.dartExecutor.binaryMessenger, CAST_PICTURE_CHANNEL)
                .setStreamHandler(it)
        }
        // The downloads notification (lib/features/downloads/downloads_service.dart).
        // A tap that launched the app is kept here rather than delivered:
        // Dart installs its handler a moment later, and a call made before
        // that would go nowhere.
        downloads = DownloadsChannel(this, flutterEngine.dartExecutor.binaryMessenger)
            .apply { pendingOpen = opensDownloads(intent) }
        // The native Drive picker (lib/core/drive_native_pick.dart), which is
        // the only picker on a phone that can choose more than one file.
        drivePicker = DrivePicker(this, flutterEngine.dartExecutor.binaryMessenger)
        localMedia = LocalMediaChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        appUpdate = AppUpdateChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        power = PowerChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        // The film's own surface (lib/features/player/video_surface.dart).
        flutterEngine.platformViewsController.registry.registerViewFactory(
            VideoSurfaceFactory.VIEW_TYPE,
            VideoSurfaceFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        speech = SpeechInput(this).also {
            EventChannel(flutterEngine.dartExecutor.binaryMessenger, SpeechInput.CHANNEL)
                .setStreamHandler(it)
        }
        hwProbe = HwProbe(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    // Hidden is the end of listening: nothing is recorded while the viewer
    // is somewhere else. Not onPause, which the microphone permission's own
    // dialog causes in the middle of the press that asked for it.
    override fun onStop() {
        speech?.stop()
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // The notification's body, with the app already running.
        if (opensDownloads(intent)) downloads?.openRequested()
    }

    // A window shown again after being stopped (minimised, behind another
    // app) can come back with no view inside it focused. Keys go to the
    // focused view, so with none, Space only takes the window out of touch
    // mode and a media key falls through to the last app registered for
    // media buttons. This hands focus back to Flutter, and only when nothing
    // has it, so a native view that has focus keeps it.
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && currentFocus == null) {
            findViewById<View>(FLUTTER_VIEW_ID)?.requestFocus()
        }
    }

    /**
     * The IPv4 address the receiver with Cast device id [id] announced over
     * mDNS, or null when Android does not know one.
     *
     * `flutter_chrome_cast` maps a `CastDevice` to Dart without its address
     * (`GoogleCastClient` has the same note), but the route the Cast SDK
     * discovered still carries the device, so the address is read off that.
     * It matches on `CastDevice.getFromBundle(route.extras)?.deviceId`,
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
     * `getInet4Address()` does not exist in play-services-cast 21.5.0+.
     *
     * `getIpAddress()` is itself `@Deprecated` in 21.5.0, where the sibling
     * `getInetAddress()` is `@NonNull` and not deprecated. So the next SDK
     * bump may need to move to that one and do the narrowing itself, since
     * it answers whatever the receiver announced, and that can be an
     * `Inet6Address`.
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
        // The picker answers its own request code and says so, which is what
        // keeps two unrelated results from reading each other's data.
        if (drivePicker?.onActivityResult(requestCode, data) == true) return
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
        localMedia?.onRequestPermissionsResult(requestCode, grantResults)
        speech?.onRequestPermissionsResult(requestCode)
    }

    override fun onDestroy() {
        downloads?.detach()
        downloads = null
        castPicture?.detach()
        castPicture = null
        drivePicker?.detach()
        localMedia?.detach()
        localMedia = null
        drivePicker = null
        appUpdate?.detach()
        appUpdate = null
        power?.detach()
        power = null
        textEntry = null
        speech?.detach()
        speech = null
        hwProbe?.detach()
        hwProbe = null
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

    // All the memory the system can give apps, in bytes; 0 where it will
    // not say.
    private fun totalMemoryBytes(): Long {
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return 0L
        val info = ActivityManager.MemoryInfo()
        manager.getMemoryInfo(info)
        return info.totalMem
    }

    private companion object {
        const val DEVICE_CHANNEL = "xtremio/device"
        const val CAST_PICTURE_CHANNEL = "xtremio/cast_picture"
        const val REQUEST_TEXT_ENTRY = 4712
    }
}
