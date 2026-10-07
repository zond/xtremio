package com.zond.xtremio

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Typing by voice into the television's search field
 * (lib/shell/speech_input.dart): `startSpeech` and `stopSpeech` on the
 * `xtremio/device` channel, and what is heard on the `xtremio/speech`
 * event channel.
 *
 * **Recognized here, not handed off.** `RecognizerIntent`'s activity route
 * is Google TV's own search on a Chromecast with Google TV: it searched the
 * whole TV and never gave the words back. So the app runs a
 * [SpeechRecognizer] of its own -- the on-device one where Android 12+ has
 * it, the device's default recognition service otherwise -- and the words
 * come back as partial results while the viewer speaks and one final
 * result at the end.
 *
 * **Only while a press asked for it.** The recognizer exists from
 * `startSpeech` to its own final result or error, `stopSpeech`, the event
 * stream being cancelled, or the activity stopping (the app hidden); each
 * of those destroys it. `RECORD_AUDIO` is asked for at the first press and never otherwise.
 *
 * `startSpeech` answers `listening`, `unavailable` (no recognition service
 * on the device), `denied` (no microphone permission, after the system
 * dialog where it can still be shown) or `busy` (that dialog is up). Events are maps with a `type` of
 * `partial` or `final` and their `text`, or `error` and a word from
 * [SpeechEvents.error].
 */
class SpeechInput(private val activity: Activity) : EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null

    /** The recognizer listening now; at most one. */
    private var recognizer: SpeechRecognizer? = null

    /** A `startSpeech` waiting on the permission dialog; at most one. */
    private var pendingStart: MethodChannel.Result? = null

    /** Whether the one listening now is the on-device recognizer. */
    private var onDevice = false

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        stop()
    }

    fun start(result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            result.success(UNAVAILABLE)
            return
        }
        if (pendingStart != null) {
            result.success(BUSY)
            return
        }
        if (!granted()) {
            pendingStart = result
            activity.requestPermissions(
                arrayOf(Manifest.permission.RECORD_AUDIO),
                REQUEST_AUDIO,
            )
            return
        }
        listen(onDeviceFirst = true)
        result.success(LISTENING)
    }

    /** Answers a `startSpeech` that waited on the permission dialog. */
    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_AUDIO) return false
        val pending = pendingStart ?: return true
        pendingStart = null
        if (granted()) {
            listen(onDeviceFirst = true)
            pending.success(LISTENING)
        } else {
            pending.success(DENIED)
        }
        return true
    }

    /** Stops listening and lets the recognizer and the microphone go. */
    fun stop() {
        val current = recognizer ?: return
        recognizer = null
        current.cancel()
        current.destroy()
    }

    fun detach() {
        stop()
        sink = null
        pendingStart = null
    }

    private fun granted(): Boolean =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun listen(onDeviceFirst: Boolean) {
        stop()
        onDevice = onDeviceFirst &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)
        val created = if (onDevice && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
        } else {
            SpeechRecognizer.createSpeechRecognizer(activity)
        }
        recognizer = created
        created.setRecognitionListener(Listener(created))
        created.startListening(
            Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                )
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
            },
        )
    }

    /**
     * One recognizer's callbacks. Anything from a recognizer that is no
     * longer the current one -- stopped, or replaced -- is dropped, so a
     * late callback never reaches a field that has moved on.
     */
    private inner class Listener(private val owner: SpeechRecognizer) : RecognitionListener {
        private var heardAnything = false

        private fun current() = recognizer === owner

        override fun onPartialResults(partialResults: Bundle?) {
            if (!current()) return
            val text = SpeechEvents.first(
                partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION),
            ) ?: return
            heardAnything = true
            sink?.success(SpeechEvents.partial(text))
        }

        override fun onResults(results: Bundle?) {
            if (!current()) return
            val text = SpeechEvents.first(
                results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION),
            )
            stop()
            sink?.success(
                if (text == null) {
                    SpeechEvents.failed(SpeechRecognizer.ERROR_NO_MATCH)
                } else {
                    SpeechEvents.final(text)
                },
            )
        }

        override fun onError(error: Int) {
            if (!current()) return
            // The on-device recognizer without this language's model: the
            // device's recognition service may have it, so it is asked once
            // before anything is said to the viewer.
            if (onDevice && !heardAnything && SpeechEvents.isMissingLanguage(error)) {
                listen(onDeviceFirst = false)
                return
            }
            stop()
            sink?.success(SpeechEvents.failed(error))
        }

        override fun onReadyForSpeech(params: Bundle?) = Unit
        override fun onBeginningOfSpeech() = Unit
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() = Unit
        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }

    companion object {
        const val CHANNEL = "xtremio/speech"
        const val LISTENING = "listening"
        const val UNAVAILABLE = "unavailable"
        const val DENIED = "denied"

        /** A press while the permission dialog is still up: nothing to do. */
        const val BUSY = "busy"

        /** Apart from DownloadsChannel's 4711 and LocalMediaChannel's 4712. */
        const val REQUEST_AUDIO = 4714
    }
}

/**
 * What crosses to Dart (`SpeechEvent` in lib/shell/speech_input.dart): a
 * transcript, or one word for what went wrong, never Android's code. No
 * Android in it beyond the error constants, so a JVM test covers it.
 */
object SpeechEvents {
    fun partial(text: String): Map<String, Any?> = mapOf("type" to "partial", "text" to text)

    fun final(text: String): Map<String, Any?> = mapOf("type" to "final", "text" to text)

    fun failed(error: Int): Map<String, Any?> = mapOf("type" to "error", "error" to error(error))

    /** The top transcript; null for none or an empty one. */
    fun first(results: List<String>?): String? =
        results?.firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }

    fun error(code: Int): String = when (code) {
        SpeechRecognizer.ERROR_NO_MATCH,
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
        -> "noMatch"
        SpeechRecognizer.ERROR_AUDIO -> "audio"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permission"
        SpeechRecognizer.ERROR_NETWORK,
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
        SpeechRecognizer.ERROR_SERVER,
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED,
        SpeechRecognizer.ERROR_TOO_MANY_REQUESTS,
        -> "network"
        else -> "other"
    }

    /** The on-device recognizer has no model for the language. */
    fun isMissingLanguage(code: Int): Boolean =
        code == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED ||
            code == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE
}
