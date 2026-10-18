package com.zond.xtremio

import android.content.Context
import android.os.PowerManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The `xtremio/power` channel: keeps the processor running while the phone
 * converts a film's picture for a cast receiver (lib/core/keep_awake.dart).
 *
 * The conversion runs on the phone's hardware codecs whenever the receiver
 * asks for more of the film, usually with the screen off. The cast's media
 * playback foreground service keeps the process alive, not the processor
 * awake, so Dart holds this from the publish of a rendition whose picture is
 * converted until that publication is withdrawn.
 *
 * From Dart: `holdAwake` and `releaseAwake`. One partial wake lock, not
 * reference counted, so a second hold is the same hold and one release lets
 * it go. It is acquired with a [SAFETY_TIMEOUT_MS] timeout, so a Dart side
 * that never releases (a crash) cannot keep the phone awake for good. It is
 * let go with the activity ([detach]).
 */
class PowerChannel(context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)

    private val lock: PowerManager.WakeLock =
        (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, TAG)
            .apply { setReferenceCounted(false) }

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "holdAwake" -> {
                lock.acquire(SAFETY_TIMEOUT_MS)
                result.success(null)
            }
            "releaseAwake" -> {
                release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Lets the lock go and stops answering: the activity is going. */
    fun detach() {
        channel.setMethodCallHandler(null)
        release()
    }

    private fun release() {
        if (lock.isHeld) lock.release()
    }

    private companion object {
        const val CHANNEL = "xtremio/power"
        const val TAG = "xtremio:rendition"

        /** Six hours: longer than any film, short of forever. */
        const val SAFETY_TIMEOUT_MS = 6L * 60 * 60 * 1000
    }
}
