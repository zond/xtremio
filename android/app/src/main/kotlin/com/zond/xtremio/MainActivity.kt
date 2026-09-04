package com.zond.xtremio

import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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
        // "a phone" on any error, so this only ever reports, never throws.
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
                    // A string typed on a screen of the platform's own,
                    // which is the only way a remote can type at all
                    // (lib/shell/tv_text_entry.dart, TextEntryActivity.kt).
                    "editText" -> editText(call, result)
                    else -> result.notImplemented()
                }
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
        const val REQUEST_TEXT_ENTRY = 4712
    }
}
