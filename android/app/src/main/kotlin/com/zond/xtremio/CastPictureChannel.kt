package com.zond.xtremio

import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import io.flutter.plugin.common.EventChannel

/**
 * **Whether the receiver is showing a picture**, as the receiver itself
 * reports it: the `videoInfo` of its media status (width, height, HDR type),
 * which a receiver decoding the film's picture reports from BUFFERING on
 * and one that cannot decode it never does -- measured 2026-10-05 on a
 * Chromecast with Google TV 4K, where an AV1 MP4 went BUFFERING to PLAYING
 * with its position advancing and no `videoInfo` at all.
 *
 * flutter_chrome_cast drops the field (its status is built from a subset of
 * `MediaStatus`), so this listens beside it: a second callback on the same
 * `RemoteMediaClient` the plugin's session owns, reached through the
 * shared `CastContext` (never created here: no context, no report), and
 * re-attached as sessions start and end. Every status update sends one
 * event: the picture as a map, or null when the status carries none.
 * Registered only while Dart is subscribed (lib/features/cast/
 * google_cast_client.dart). The wiring needs a device; [CastPicture] is the
 * part a JVM test reaches.
 */
class CastPictureChannel : EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null
    private var client: RemoteMediaClient? = null

    private val callback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() = report()
    }

    private val sessions = object : SessionManagerListener<CastSession> {
        override fun onSessionStarted(session: CastSession, sessionId: String) = attach(session)
        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) =
            attach(session)
        override fun onSessionEnded(session: CastSession, error: Int) = attach(null)
        override fun onSessionSuspended(session: CastSession, reason: Int) = attach(null)
        override fun onSessionStarting(session: CastSession) = Unit
        override fun onSessionStartFailed(session: CastSession, error: Int) = Unit
        override fun onSessionEnding(session: CastSession) = Unit
        override fun onSessionResuming(session: CastSession, sessionId: String) = Unit
        override fun onSessionResumeFailed(session: CastSession, error: Int) = Unit
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val manager = castContext()?.sessionManager ?: return
        manager.addSessionManagerListener(sessions, CastSession::class.java)
        attach(manager.currentCastSession)
    }

    override fun onCancel(arguments: Any?) = detach()

    /** Lets the session go, whether Dart cancelled or the activity did. */
    fun detach() {
        castContext()?.sessionManager?.removeSessionManagerListener(
            sessions,
            CastSession::class.java,
        )
        attach(null)
        sink = null
    }

    private fun attach(session: CastSession?) {
        client?.unregisterCallback(callback)
        client = session?.remoteMediaClient
        client?.registerCallback(callback)
        report()
    }

    private fun report() {
        val info = client?.mediaStatus?.videoInfo
        sink?.success(info?.let { CastPicture.of(it.width, it.height, it.hdrType) })
    }

    /**
     * The plugin's `CastContext`, or null before it has made one: the
     * no-argument lookup never initialises the SDK, and a failure is no
     * report rather than a crash.
     */
    private fun castContext(): CastContext? = try {
        CastContext.getSharedInstance()
    } catch (error: IllegalStateException) {
        null
    }
}

/** A receiver's `videoInfo` as Dart reads it. No Android in it. */
object CastPicture {
    /**
     * `{width, height, hdr}`, `hdr` one of `sdr`, `hdr10`, `dolbyVision`,
     * `hdr` or `unknown` (`VideoInfo.HDR_TYPE_*`, 0 to 4); null for a
     * picture with no size, which is no picture.
     */
    fun of(width: Int, height: Int, hdrType: Int): Map<String, Any>? {
        if (width <= 0 || height <= 0) return null
        val hdr = when (hdrType) {
            1 -> "sdr"
            2 -> "hdr10"
            3 -> "dolbyVision"
            4 -> "hdr"
            else -> "unknown"
        }
        return mapOf("width" to width, "height" to height, "hdr" to hdr)
    }
}
