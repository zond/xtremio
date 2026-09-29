package com.zond.xtremio

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The `xtremio/local_media` channel: the videos Android's media index
 * (MediaStore) knows of, for the Library's Local list
 * (lib/features/local/android_local_media_source.dart).
 *
 * From Dart: `access` ("granted", "askable" or "unavailable"),
 * `requestAccess` (the same, after the system dialog), and `scan` (one map
 * per video: `uri`, `name`, `size`, `durationMillis`, `height`, `folder`).
 *
 * **The index, not the disk.** MediaStore already knows every video on the
 * device's storage and on a USB drive plugged into it, so nothing here
 * walks a directory; a `content://` address is what comes back, which the
 * player opens as a file descriptor. **The camera's own folders are left
 * out** -- `DCIM/` and `Pictures/` (screen recordings live there too): a
 * phone holds hundreds of its own clips, and a list of them is not a
 * library of films.
 *
 * The permission is `READ_MEDIA_VIDEO` from Android 13, and the storage
 * read before it. On Android 14 a viewer may grant only some videos, which
 * MediaStore then answers with, so that counts as granted.
 */
class LocalMediaChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** In flight while the permission dialog is up; at most one. */
    private var permission: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(this)
    }

    fun detach() {
        channel.setMethodCallHandler(null)
        permission = null
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "access" -> result.success(if (granted()) GRANTED else ASKABLE)
            "requestAccess" -> request(result)
            "scan" -> scan(result)
            else -> result.notImplemented()
        }
    }

    private fun permissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= 34 -> arrayOf(
            Manifest.permission.READ_MEDIA_VIDEO,
            Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
        )
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
            arrayOf(Manifest.permission.READ_MEDIA_VIDEO)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    private fun granted(): Boolean = permissions().any {
        ContextCompat.checkSelfPermission(activity, it) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun request(result: MethodChannel.Result) {
        if (granted()) {
            result.success(GRANTED)
            return
        }
        if (permission != null) {
            result.success(ASKABLE)
            return
        }
        permission = result
        activity.requestPermissions(permissions(), REQUEST_MEDIA)
    }

    /** Answers the pending `requestAccess`. */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_MEDIA) return false
        val pending = permission ?: return true
        permission = null
        val answer = when {
            granted() -> GRANTED
            // Refused with "don't ask again", or refused twice: the dialog
            // will not come back, so pressing again would do nothing.
            permissions().none { activity.shouldShowRequestPermissionRationale(it) } ->
                UNAVAILABLE
            else -> ASKABLE
        }
        pending.success(answer)
        return true
    }

    private fun scan(result: MethodChannel.Result) {
        if (!granted()) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }
        executor.execute {
            val rows = try {
                query()
            } catch (error: RuntimeException) {
                main.post { result.error("scan_failed", error.javaClass.simpleName, null) }
                return@execute
            }
            main.post { result.success(rows) }
        }
    }

    private fun query(): List<Map<String, Any?>> {
        val collection: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Every external volume, a USB drive's included.
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        val where = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Video.Media.RELATIVE_PATH
        } else {
            @Suppress("DEPRECATION")
            MediaStore.Video.Media.DATA
        }
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.HEIGHT,
            where,
        )
        val rows = mutableListOf<Map<String, Any?>>()
        activity.contentResolver.query(
            collection,
            projection,
            null,
            null,
            "${MediaStore.Video.Media.DATE_ADDED} DESC",
        )?.use { cursor ->
            val id = cursor.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
            val name = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DISPLAY_NAME)
            val size = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.SIZE)
            val duration = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DURATION)
            val height = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.HEIGHT)
            val path = cursor.getColumnIndexOrThrow(where)
            while (cursor.moveToNext()) {
                val folder = cursor.getString(path)
                if (isCameraFolder(folder)) continue
                val displayName = cursor.getString(name) ?: continue
                rows.add(
                    mapOf(
                        "uri" to ContentUris.withAppendedId(collection, cursor.getLong(id))
                            .toString(),
                        "name" to displayName,
                        "size" to cursor.longOrNull(size),
                        "durationMillis" to cursor.longOrNull(duration),
                        "height" to cursor.longOrNull(height),
                        // For the Dart side's sample rule.
                        "folder" to innermostFolder(folder, Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q),
                    ),
                )
            }
        }
        return rows
    }

    private fun android.database.Cursor.longOrNull(index: Int): Long? =
        if (isNull(index)) null else getLong(index).takeIf { it > 0 }

    private companion object {
        const val CHANNEL = "xtremio/local_media"
        const val REQUEST_MEDIA = 4712
        const val GRANTED = "granted"
        const val ASKABLE = "askable"
        const val UNAVAILABLE = "unavailable"

        /**
         * `DCIM/Camera/` and the like: a relative path from Android 10, a
         * whole path before it, so both are matched on the folder's name.
         */
        /**
         * The name of the folder a video is in: the last part of a relative
         * path (Android 10 on), or the one before the file's own name in a
         * whole path (before it).
         */
        fun innermostFolder(path: String?, relative: Boolean): String? {
            val parts = path?.split('/')?.filter { it.isNotEmpty() } ?: return null
            return if (relative) parts.lastOrNull() else parts.dropLast(1).lastOrNull()
        }

        fun isCameraFolder(path: String?): Boolean {
            if (path == null) return false
            val normalised = "/" + path.trimStart('/')
            return normalised.startsWith("/DCIM/") ||
                normalised.startsWith("/Pictures/") ||
                normalised.contains("/DCIM/") ||
                normalised.contains("/Pictures/")
        }
    }
}
