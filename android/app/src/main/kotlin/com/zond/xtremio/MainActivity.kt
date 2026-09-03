package com.zond.xtremio

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
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
                    else -> result.notImplemented()
                }
            }
    }

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
    }
}
