package com.zond.xtremio

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The `xtremio/downloads` channel: everything the downloads foreground
 * service needs from the platform, and the two things the platform needs
 * to tell Dart.
 *
 * A sibling of the `xtremio/device` channel in [MainActivity] and a
 * separate concern from it — that one is asked once, at start-up, what kind
 * of device this is; this one is a running conversation about downloads.
 *
 * From Dart: `start` and `update` (the notification's title, text,
 * percentage and action label), `stop`, `requestNotificationPermission`,
 * and `takePendingOpen` for a tap that arrived before Dart had a handler
 * installed. To Dart: `open` (the notification was tapped) and `cancelAll`
 * (its action was pressed) — the registry is behind the FFI, so only Dart
 * can act on either.
 */
class DownloadsChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)

    /** In flight while the notifications dialog is up; at most one. */
    private var permission: MethodChannel.Result? = null

    /**
     * A notification tapped while there was no Dart handler yet — the app
     * was cold started by it. Dart asks for this once it is up.
     */
    var pendingOpen: Boolean = false

    init {
        channel.setMethodCallHandler(this)
        DownloadsService.channel = this
    }

    /** Lets go of both halves; the activity is going away. */
    fun detach() {
        channel.setMethodCallHandler(null)
        permission = null
        if (DownloadsService.channel === this) DownloadsService.channel = null
    }

    fun openRequested() = channel.invokeMethod("open", null)

    fun cancelAllRequested() = channel.invokeMethod("cancelAll", null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start", "update" -> show(call, result)
            "stop" -> {
                activity.stopService(Intent(activity, DownloadsService::class.java))
                result.success(null)
            }
            "requestNotificationPermission" -> requestNotifications(result)
            "takePendingOpen" -> {
                val pending = pendingOpen
                pendingOpen = false
                result.success(pending)
            }
            else -> result.notImplemented()
        }
    }

    private fun show(call: MethodCall, result: MethodChannel.Result) {
        val intent = Intent(activity, DownloadsService::class.java).apply {
            putExtra(DownloadsService.EXTRA_TITLE, call.argument<String>("title"))
            putExtra(DownloadsService.EXTRA_TEXT, call.argument<String>("text"))
            putExtra(DownloadsService.EXTRA_PROGRESS, call.argument<Int>("progress") ?: -1)
            putExtra(
                DownloadsService.EXTRA_CANCEL_LABEL,
                call.argument<String>("cancelLabel"),
            )
        }
        try {
            ContextCompat.startForegroundService(activity, intent)
            result.success(null)
        } catch (error: IllegalStateException) {
            // API 31+ refuses one started from the background. Dart treats a
            // failure as "no service" and asks again on the next change.
            result.error("service_refused", error.message, null)
        } catch (error: SecurityException) {
            result.error("service_refused", error.message, null)
        }
    }

    /**
     * Asks for `POST_NOTIFICATIONS` if it is a thing on this release and
     * has not been granted. Dart asks only when a download has actually
     * started, and only once a run; a refusal is answered `false` and
     * changes nothing else — the service still runs, silently.
     */
    private fun requestNotifications(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val granted = ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        if (permission != null) {
            // A dialog is already up; this caller is not made to wait on it.
            result.success(false)
            return
        }
        permission = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATIONS,
        )
    }

    /** Answers the pending `requestNotificationPermission`. */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_NOTIFICATIONS) return false
        val pending = permission ?: return true
        permission = null
        pending.success(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED,
        )
        return true
    }

    private companion object {
        const val CHANNEL = "xtremio/downloads"
        const val REQUEST_NOTIFICATIONS = 4711
    }
}
