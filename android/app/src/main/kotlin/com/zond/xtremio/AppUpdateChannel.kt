package com.zond.xtremio

import android.app.Activity
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/**
 * The `xtremio/update` channel: installing a release APK the app has
 * downloaded and verified (lib/features/update/apk_installer.dart).
 *
 * From Dart: `abi` (`Build.SUPPORTED_ABIS[0]`, which chooses the APK),
 * `canRequestInstalls` (the per-app "Install unknown apps" switch),
 * `openInstallPermission` (that switch's screen; false where nothing
 * answers the intent) and `install`, which answers with an
 * [InstallOutcome] map once the session is over.
 *
 * **Never silent.** The session asks for user action outright
 * (`USER_ACTION_REQUIRED`), so Android puts its own confirmation up even
 * where it would have let an update by the installer of record through
 * without one. The confirmation arrives as `STATUS_PENDING_USER_ACTION` at
 * [InstallStatusReceiver] and is started from here; what the viewer
 * answers comes back the same way. A self-update that succeeds ends this
 * process, usually before the success is delivered.
 *
 * **The release app only.** Debug and profile builds are
 * `com.zond.xtremio.debug`, signed with the debug key; a release APK is a
 * different package to them, so `install` refuses there rather than put a
 * second app on the device. Dart never offers it there either.
 */
class AppUpdateChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** The `install` call waiting for its session to end; at most one. */
    private var pending: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(this)
        current = this
    }

    fun detach() {
        channel.setMethodCallHandler(null)
        pending = null
        executor.shutdown()
        if (current === this) current = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "abi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull())
            "canRequestInstalls" -> result.success(canRequestInstalls())
            "openInstallPermission" -> result.success(openInstallPermission())
            "install" -> install(call.argument<String>("path"), result)
            else -> result.notImplemented()
        }
    }

    private fun canRequestInstalls(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            activity.packageManager.canRequestPackageInstalls()

    /**
     * This app's "Install unknown apps" screen. Not resolved first: under
     * package visibility a resolve can answer null for a Settings screen
     * that opens fine, so it is started and a device with nothing behind it
     * is told apart by the exception.
     */
    private fun openInstallPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}"),
                ),
            )
            true
        } catch (error: ActivityNotFoundException) {
            false
        } catch (error: SecurityException) {
            false
        }
    }

    private fun install(path: String?, result: MethodChannel.Result) {
        if (activity.packageName != RELEASE_PACKAGE) {
            result.error("not_release", "only the release app installs updates", null)
            return
        }
        val file = path?.let(::File)
        if (file == null || !file.isFile) {
            result.error("no_file", "the downloaded update is gone", null)
            return
        }
        if (pending != null) {
            result.error("busy", "an install is already waiting", null)
            return
        }
        pending = result
        executor.execute {
            try {
                commit(file)
            } catch (error: IOException) {
                main.post { finish(InstallOutcome.of(-1, error.message)) }
            } catch (error: SecurityException) {
                main.post { finish(InstallOutcome.of(-1, error.message)) }
            }
        }
    }

    /** Writes [file] into a new session and commits it; off the main thread. */
    private fun commit(file: File) {
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL,
        ).apply {
            setAppPackageName(RELEASE_PACKAGE)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setRequireUserAction(
                    PackageInstaller.SessionParams.USER_ACTION_REQUIRED,
                )
            }
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("xtremio.apk", 0, file.length()).use { out ->
                file.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            val intent = Intent(activity, InstallStatusReceiver::class.java)
            // Mutable: the installer writes the status into it.
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
            val status = PendingIntent.getBroadcast(activity, id, intent, flags)
            session.commit(status.intentSender)
        }
    }

    /** A status [InstallStatusReceiver] passed on; on the main thread. */
    fun onStatus(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            confirm(context, intent)
            return
        }
        finish(
            InstallOutcome.of(
                status,
                intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE),
            ),
        )
    }

    private fun confirm(context: Context, intent: Intent) {
        val confirmation = confirmationOf(intent)
        if (confirmation == null) {
            finish(InstallOutcome.of(-1, "Android gave no confirmation screen"))
            return
        }
        try {
            activity.startActivity(confirmation)
        } catch (error: ActivityNotFoundException) {
            finish(InstallOutcome.of(-1, error.message))
        }
    }

    private fun finish(outcome: Map<String, Any?>) {
        val result = pending ?: return
        pending = null
        result.success(outcome)
    }

    companion object {
        const val CHANNEL = "xtremio/update"

        /** The release app's package; the debug one has `.debug` on it. */
        const val RELEASE_PACKAGE = "com.zond.xtremio"

        /** The channel alive now, for [InstallStatusReceiver]. */
        @Volatile
        var current: AppUpdateChannel? = null

        @Suppress("DEPRECATION")
        fun confirmationOf(intent: Intent): Intent? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }
    }
}

/**
 * Where a `PackageInstaller` session reports. Declared in the manifest and
 * not exported, so only the installer's `PendingIntent` reaches it.
 *
 * With the activity gone (the viewer left while Android was working) a
 * confirmation is still put up, as a new task -- the install was asked for
 * and Android's screen is where it is answered -- and a final status has
 * nobody to tell.
 */
class InstallStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val channel = AppUpdateChannel.current
        if (channel != null) {
            channel.onStatus(context, intent)
            return
        }
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
        if (status != PackageInstaller.STATUS_PENDING_USER_ACTION) return
        val confirmation = AppUpdateChannel.confirmationOf(intent) ?: return
        try {
            context.startActivity(confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (error: ActivityNotFoundException) {
            // Nothing to show it with; the install is simply not confirmed.
        }
    }
}

/**
 * A `PackageInstaller` status as the Dart side reads it
 * (`InstallResult` in lib/features/update/apk_installer.dart): one word for
 * what happened, and Android's own message. No Android in it beyond the
 * status constants, so a JVM test covers it.
 */
object InstallOutcome {
    fun of(status: Int, message: String?): Map<String, Any?> =
        mapOf("outcome" to name(status), "message" to message)

    fun name(status: Int): String = when (status) {
        PackageInstaller.STATUS_SUCCESS -> "success"
        PackageInstaller.STATUS_FAILURE_ABORTED -> "aborted"
        // A signature that does not match the installed app's is this one:
        // INSTALL_FAILED_UPDATE_INCOMPATIBLE reaches a session as a
        // conflict.
        PackageInstaller.STATUS_FAILURE_CONFLICT -> "conflict"
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "incompatible"
        PackageInstaller.STATUS_FAILURE_INVALID -> "invalid"
        PackageInstaller.STATUS_FAILURE_STORAGE -> "storage"
        PackageInstaller.STATUS_FAILURE_BLOCKED -> "blocked"
        else -> "failure"
    }
}
