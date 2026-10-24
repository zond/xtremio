package com.zond.xtremio

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * The film's own SurfaceView (lib/features/player/video_surface.dart), the
 * `xtremio/video_surface` platform view: mpv's `vo=mediacodec_embed` has
 * MediaCodec decode straight into it, and the display hardware shows it.
 *
 * Each view opens the channel `xtremio/video_surface_<id>` and says two
 * things on it. `surface` comes when the surface exists or changes size, with
 * `wid` (a JNI global reference to the Surface, the value mpv takes as `wid`)
 * and its size. `gone` comes when the surface is destroyed: the view left the
 * screen or the app went to the background.
 *
 * The reference is made by media_kit's own helper, as media_kit makes its
 * texture's, and deleted five seconds after `gone`, as media_kit does, so mpv
 * has let go of it first.
 */
class VideoSurfaceFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        VideoSurface(context, viewId, messenger)

    companion object {
        const val VIEW_TYPE = "xtremio/video_surface"
    }
}

class VideoSurface(context: Context, viewId: Int, messenger: BinaryMessenger) :
    PlatformView, SurfaceHolder.Callback {
    private val channel = MethodChannel(messenger, "${VideoSurfaceFactory.VIEW_TYPE}_$viewId")
    private val surfaceView = SurfaceView(context).also { it.holder.addCallback(this) }
    private val handler = Handler(Looper.getMainLooper())
    private var ref = 0L

    override fun getView(): View = surfaceView

    override fun dispose() {
        surfaceView.holder.removeCallback(this)
        release()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {}

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        if (ref == 0L) ref = MediaKitAndroidHelper.newGlobalObjectRef(holder.surface)
        channel.invokeMethod("surface", mapOf("wid" to ref, "width" to width, "height" to height))
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        channel.invokeMethod("gone", null)
        release()
    }

    private fun release() {
        val old = ref
        ref = 0L
        if (old != 0L) {
            handler.postDelayed({ MediaKitAndroidHelper.deleteGlobalObjectRef(old) }, RELEASE_DELAY_MS)
        }
    }

    private companion object {
        const val RELEASE_DELAY_MS = 5000L
    }
}
