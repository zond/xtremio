package com.zond.xtremio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Keeps the process alive and un-frozen while offline downloads are on
 * their way, and says so with an ongoing notification.
 *
 * It hosts nothing. The embedded stream-server and librqbit already run on
 * their own threads inside this process; what Android takes away when the
 * user leaves the app is the *right to keep running*, and a `dataSync`
 * foreground service is how an app asks for it. Everything about which
 * downloads exist and how far along they are is decided on the Dart side
 * ([DownloadsChannel]), which starts this, feeds it a line of text and a
 * percentage, and stops it as soon as nothing is unfinished.
 *
 * What it does not promise: the system may still kill the process under
 * memory pressure, and Doze or the per-app battery optimisation may throttle
 * or park the sockets. Nothing is lost when that happens — librqbit keeps
 * its verified pieces and start-up re-pins every unfinished entry. Swiping
 * the app out of recents stops it outright (`android:stopWithTask`): the
 * Flutter engine goes at the same moment, and a notification nobody can
 * move on or take down is worse than no notification.
 */
class DownloadsService : Service() {
    /** The last thing Dart asked for, so an action intent can rebuild it. */
    private var content = Content()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent != null && intent.hasExtra(EXTRA_TITLE)) {
            content = Content.from(intent)
        }
        // Whatever brought us here — a fresh start, an update, or the action
        // on the notification — the service has seconds to reach the
        // foreground, so post first and act afterwards.
        if (!startForegroundWith(content)) return START_NOT_STICKY
        if (intent?.action == ACTION_CANCEL_ALL) {
            // Only Dart can drop a download: the registry is behind the FFI.
            // With no engine to ask there is nothing to cancel and nothing
            // left to report progress either, so the service goes.
            val dart = channel
            if (dart == null) stopSelf() else dart.cancelAllRequested()
        }
        // Not sticky: a process the system killed is restarted by the user
        // opening the app, which re-pins and starts this again. A service
        // brought back on its own would have no Dart side behind it.
        return START_NOT_STICKY
    }

    private fun startForegroundWith(content: Content): Boolean {
        ensureChannel()
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification(content),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification(content))
            }
            true
        } catch (error: IllegalStateException) {
            // API 31+ refuses a foreground service started from the
            // background; API 34+ refuses a type the app cannot hold.
            // Downloads still run while the app is in front.
            Log.w(TAG, "the downloads service could not go to the foreground", error)
            stopSelf()
            false
        } catch (error: SecurityException) {
            Log.w(TAG, "the downloads service was refused its type", error)
            stopSelf()
            false
        }
    }

    /** A channel of its own, at low importance: this must never buzz. */
    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Progress of the titles being kept on this device."
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            },
        )
    }

    private fun notification(content: Content): Notification {
        val bar = DownloadsProgressBar.of(content.progress)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(content.title)
            .setContentText(content.text)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setProgress(bar.max, bar.current, bar.indeterminate)
            .setContentIntent(openDownloads())
            .addAction(0, content.cancelLabel, cancelAll())
            .build()
    }

    /** Tapping the body opens the app on its Downloads screen. */
    private fun openDownloads(): PendingIntent = PendingIntent.getActivity(
        this,
        REQUEST_OPEN,
        Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_OPEN_DOWNLOADS, true)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /**
     * The one action. Starting an already-running foreground service from
     * the background is allowed, which is what makes this reachable while
     * the app is away.
     */
    private fun cancelAll(): PendingIntent = PendingIntent.getService(
        this,
        REQUEST_CANCEL,
        Intent(this, DownloadsService::class.java).setAction(ACTION_CANCEL_ALL),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /** What the notification says, as Dart sent it. */
    private data class Content(
        val title: String = "Downloading",
        val text: String = "",
        val progress: Int = -1,
        val cancelLabel: String = "Cancel all",
    ) {
        companion object {
            fun from(intent: Intent): Content = Content(
                title = intent.getStringExtra(EXTRA_TITLE) ?: "Downloading",
                text = intent.getStringExtra(EXTRA_TEXT).orEmpty(),
                progress = intent.getIntExtra(EXTRA_PROGRESS, -1),
                cancelLabel = intent.getStringExtra(EXTRA_CANCEL_LABEL) ?: "Cancel all",
            )
        }
    }

    companion object {
        private const val TAG = "XtremioDownloads"
        private const val CHANNEL_ID = "xtremio.downloads"
        private const val NOTIFICATION_ID = 4711
        private const val REQUEST_OPEN = 1
        private const val REQUEST_CANCEL = 2

        const val ACTION_CANCEL_ALL = "com.zond.xtremio.downloads.CANCEL_ALL"
        const val EXTRA_TITLE = "com.zond.xtremio.downloads.TITLE"
        const val EXTRA_TEXT = "com.zond.xtremio.downloads.TEXT"
        const val EXTRA_PROGRESS = "com.zond.xtremio.downloads.PROGRESS"
        const val EXTRA_CANCEL_LABEL = "com.zond.xtremio.downloads.CANCEL_LABEL"

        /** Set on the intent the notification's body opens the app with. */
        const val EXTRA_OPEN_DOWNLOADS = "com.zond.xtremio.downloads.OPEN"

        /**
         * The Dart side, while there is one. A notification action arrives
         * at the service, not at the activity, and the registry it has to
         * act on is behind the FFI, so the service needs a way back.
         * [DownloadsChannel] puts itself here when the engine is configured
         * and clears it when the activity is destroyed, so this never
         * outlives the activity it points at.
         */
        var channel: DownloadsChannel? = null
    }
}
