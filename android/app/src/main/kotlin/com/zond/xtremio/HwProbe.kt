package com.zond.xtremio

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.ImageFormat
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecCapabilities
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.provider.MediaStore
import android.view.Surface
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * A developer-only hardware codec probe, on the `xtremio/hwprobe` channel.
 *
 * It answers what only the phone can: which video codecs it has and what
 * they claim, and how fast and how repeatably its hardware encoder
 * re-encodes a film's picture (docs/DRIVING.md, "The codec probe").
 * Only the driver calls it: `tool/hwprobe` sends the methods through
 * `tool/drive` and `lib/dev/driver/app_driver.dart`. Nothing in the app
 * does, so it is harmless in a release build. It goes, with
 * HwProbeRules.kt and `tool/hwprobe`, when the real conversion is built.
 *
 * The codecs run the way the Rust side will drive them through the NDK:
 * synchronous dequeue loops with a 10 ms wait, on one worker thread, with
 * no callbacks and no Handler. Every answer is a map of plain values.
 */
class HwProbe(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** The current or last run; at most one runs at a time. */
    @Volatile
    private var run: Any? = null

    init {
        channel.setMethodCallHandler(this)
    }

    fun detach() {
        channel.setMethodCallHandler(null)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) (run as? ProbeRun)?.stop()
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("unsupported", "the codec probe needs Android 10 or later", null)
            return
        }
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
        val current = run as? ProbeRun
        when (call.method) {
            "codecs" -> background(result) { codecsReport(context) }
            "instances" -> background(result) { instances(args) }
            "start" -> {
                if (current != null && current.running) {
                    result.error("busy", "a run is going: ${current.label}", null)
                    return
                }
                val next = try {
                    ProbeRun(context.applicationContext, ProbeArgs(args))
                } catch (error: IllegalArgumentException) {
                    result.error("args", error.message, null)
                    return
                }
                run = next
                next.start()
                result.success(mapOf("started" to next.label))
            }
            "status" -> result.success(
                current?.status()
                    ?: mapOf("running" to false, "done" to false, "error" to null, "now" to now(context)),
            )
            "stop" -> {
                current?.stop()
                result.success(mapOf("stopping" to (current?.running == true)))
            }
            "result" -> when {
                current == null -> result.error("none", "no run yet", null)
                current.running -> result.error("running", "the run is still going; stop it or wait", null)
                else -> result.success(current.report())
            }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        executor.execute {
            val answer = runCatching(work)
            main.post {
                answer.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("failed", describe(it), null) },
                )
            }
        }
    }

    // ------------------------------------------------------------ codecs

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun instances(args: Map<*, *>): Map<String, Any?> {
        val mime = args["mime"] as? String ?: "video/hevc"
        val width = (args["width"] as? Number)?.toInt() ?: 3840
        val height = (args["height"] as? Number)?.toInt() ?: 2160
        val wantEncoders = (args["encoders"] as? Number)?.toInt() ?: 0
        val wantDecoders = (args["decoders"] as? Number)?.toInt() ?: 0
        val codecs = mutableListOf<MediaCodec>()
        val surfaces = mutableListOf<Surface>()
        val readers = mutableListOf<ImageReader>()
        fun attempt(count: Int, make: () -> MediaCodec): Map<String, Any?> {
            val names = mutableListOf<String>()
            var failure: String? = null
            for (i in 0 until count) {
                try {
                    val codec = make()
                    codecs.add(codec)
                    names.add(codec.name)
                } catch (error: Throwable) {
                    failure = describe(error)
                    break
                }
            }
            return mapOf("asked" to count, "started" to names.size, "names" to names, "failure" to failure)
        }
        try {
            val encoders = attempt(wantEncoders) {
                val codec = MediaCodec.createEncoderByType(mime)
                try {
                    val format = MediaFormat.createVideoFormat(mime, width, height).apply {
                        setInteger(MediaFormat.KEY_COLOR_FORMAT, CodecCapabilities.COLOR_FormatSurface)
                        setInteger(MediaFormat.KEY_BIT_RATE, 12_000_000)
                        setInteger(MediaFormat.KEY_FRAME_RATE, 24)
                        setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, 1f)
                    }
                    codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    surfaces.add(codec.createInputSurface())
                    codec.start()
                } catch (error: Throwable) {
                    codec.release()
                    throw error
                }
                codec
            }
            val decoders = attempt(wantDecoders) {
                val codec = MediaCodec.createDecoderByType(mime)
                try {
                    val reader = ImageReader.newInstance(width, height, ImageFormat.PRIVATE, 4)
                    readers.add(reader)
                    codec.configure(MediaFormat.createVideoFormat(mime, width, height), reader.surface, null, 0)
                    codec.start()
                } catch (error: Throwable) {
                    codec.release()
                    throw error
                }
                codec
            }
            return mapOf(
                "mime" to mime,
                "width" to width,
                "height" to height,
                "encoders" to encoders,
                "decoders" to decoders,
            )
        } finally {
            for (codec in codecs) {
                runCatching { codec.stop() }
                runCatching { codec.release() }
            }
            surfaces.forEach { runCatching { it.release() } }
            readers.forEach { runCatching { it.close() } }
        }
    }

    companion object {
        const val CHANNEL = "xtremio/hwprobe"

        fun describe(error: Throwable): String =
            "${error.javaClass.simpleName}: ${error.message}" +
                (error.cause?.let { " (cause ${it.javaClass.simpleName}: ${it.message})" } ?: "")

        private val featureTable: List<Pair<String, Int>> = listOf(
            CodecCapabilities.FEATURE_AdaptivePlayback to 19,
            CodecCapabilities.FEATURE_SecurePlayback to 21,
            CodecCapabilities.FEATURE_TunneledPlayback to 21,
            "low-latency" to 30,
            "qp-bounds" to 31,
            "hdr-editing" to 33,
            "encoding-statistics" to 33,
            "dynamic-timestamp" to 34,
            "multiple-frames" to 34,
        )

        @RequiresApi(Build.VERSION_CODES.Q)
        fun codecsReport(context: Context): Map<String, Any?> {
            val codecs = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
                .filter { info -> info.supportedTypes.any { it.startsWith("video/") } }
                .map { codecInfo(it) }
            return mapOf("system" to system(context), "codecs" to codecs)
        }

        @RequiresApi(Build.VERSION_CODES.Q)
        fun system(context: Context): Map<String, Any?> = mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "hardware" to Build.HARDWARE,
            "socManufacturer" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MANUFACTURER else null,
            "socModel" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else null,
            "release" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT,
            "now" to now(context),
        )

        @RequiresApi(Build.VERSION_CODES.Q)
        private fun codecInfo(info: MediaCodecInfo): Map<String, Any?> = mapOf(
            "name" to info.name,
            "canonicalName" to info.canonicalName,
            "isAlias" to info.isAlias,
            "isEncoder" to info.isEncoder,
            "isHardwareAccelerated" to info.isHardwareAccelerated,
            "isSoftwareOnly" to info.isSoftwareOnly,
            "isVendor" to info.isVendor,
            "types" to info.supportedTypes.filter { it.startsWith("video/") }.map { type ->
                runCatching { typeInfo(info, type) }.getOrElse { mapOf("type" to type, "error" to describe(it)) }
            },
        )

        private fun <T : Comparable<T>> range(r: android.util.Range<T>?): List<T>? =
            r?.let { listOf(it.lower, it.upper) }

        @RequiresApi(Build.VERSION_CODES.Q)
        private fun typeInfo(info: MediaCodecInfo, type: String): Map<String, Any?> {
            val caps = info.getCapabilitiesForType(type)
            val video = caps.videoCapabilities
            val encoder = caps.encoderCapabilities
            fun rates(w: Int, h: Int): List<Double>? =
                runCatching { range(video?.getSupportedFrameRatesFor(w, h)) }.getOrNull()
            fun achievable(w: Int, h: Int): List<Double>? =
                runCatching { range(video?.getAchievableFrameRatesFor(w, h)) }.getOrNull()
            return mapOf(
                "type" to type,
                "profileLevels" to caps.profileLevels.map {
                    mapOf(
                        "profile" to it.profile,
                        "profileName" to HwProbeRules.profileName(type, it.profile),
                        "level" to it.level,
                        "levelName" to HwProbeRules.levelName(type, it.level),
                    )
                },
                "widths" to range(video?.supportedWidths),
                "heights" to range(video?.supportedHeights),
                "widthAlignment" to video?.widthAlignment,
                "heightAlignment" to video?.heightAlignment,
                "fps1080" to rates(1920, 1080),
                "fps2160" to rates(3840, 2160),
                "achievableFps1080" to achievable(1920, 1080),
                "achievableFps2160" to achievable(3840, 2160),
                "size2160" to video?.isSizeSupported(3840, 2160),
                "performancePoints" to video?.supportedPerformancePoints?.map { it.toString() },
                "bitrate" to range(video?.bitrateRange),
                "bitrateModes" to encoder?.let { e ->
                    buildMap {
                        put("cbr", e.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR))
                        put("vbr", e.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR))
                        put("cq", e.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CQ))
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            put(
                                "cbrFd",
                                e.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR_FD),
                            )
                        }
                    }
                },
                "qualityRange" to encoder?.let { range(it.qualityRange) },
                "colorFormats" to caps.colorFormats.map {
                    mapOf("format" to it, "name" to HwProbeRules.colorFormatName(it))
                },
                "p010" to caps.colorFormats.contains(HwProbeRules.COLOR_P010),
                "surface" to caps.colorFormats.contains(HwProbeRules.COLOR_SURFACE),
                "features" to featureTable.filter { Build.VERSION.SDK_INT >= it.second }
                    .associate { (name, _) -> name to caps.isFeatureSupported(name) },
                "maxInstances" to caps.maxSupportedInstances,
            )
        }

        /** What the phone is doing right now: heat, battery, screen. */
        fun now(context: Context): Map<String, Any?> {
            val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val manager = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            val tenths = battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
            val currentUa = manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
            val thermal = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) power.currentThermalStatus else null
            val headroom = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                power.getThermalHeadroom(10).takeIf { it.isFinite() }?.toDouble()
            } else {
                null
            }
            return mapOf(
                "elapsedRealtimeMs" to SystemClock.elapsedRealtime(),
                "thermal" to thermal,
                "thermalName" to thermal?.let { HwProbeRules.thermalName(it) },
                "thermalHeadroom10s" to headroom,
                "screenOn" to power.isInteractive,
                "batteryPercent" to if (level >= 0 && scale > 0) level * 100.0 / scale else null,
                "batteryC" to tenths?.takeIf { it != Int.MIN_VALUE }?.let { it / 10.0 },
                // The sign of CURRENT_NOW is the vendor's choice: on some
                // phones negative is discharging, on others positive.
                "currentMa" to if (currentUa == Int.MIN_VALUE) null else currentUa / 1000.0,
                "plugged" to battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1)?.let {
                    if (it < 0) null else HwProbeRules.pluggedName(it)
                },
            )
        }

        /** The keys of a format the report wants, plus its whole `toString`. */
        @RequiresApi(Build.VERSION_CODES.Q)
        fun describeFormat(format: MediaFormat): Map<String, Any?> {
            val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
            fun int(key: String): Int? = if (format.containsKey(key)) runCatching { format.getInteger(key) }.getOrNull() else null
            fun bytes(key: String): String? =
                if (format.containsKey(key)) runCatching { bufferHex(format.getByteBuffer(key)) }.getOrNull() else null
            val profile = int(MediaFormat.KEY_PROFILE)
            val level = int(MediaFormat.KEY_LEVEL)
            val colorFormat = int(MediaFormat.KEY_COLOR_FORMAT)
            return mapOf(
                "string" to format.toString(),
                "mime" to mime,
                "width" to int(MediaFormat.KEY_WIDTH),
                "height" to int(MediaFormat.KEY_HEIGHT),
                "crop" to listOf("crop-left", "crop-top", "crop-right", "crop-bottom").map { int(it) }
                    .takeIf { c -> c.any { it != null } },
                "colorFormat" to colorFormat,
                "colorFormatName" to colorFormat?.let { HwProbeRules.colorFormatName(it) },
                "colorStandard" to int(MediaFormat.KEY_COLOR_STANDARD),
                "colorTransfer" to int(MediaFormat.KEY_COLOR_TRANSFER),
                "colorRange" to int(MediaFormat.KEY_COLOR_RANGE),
                "hdrStaticInfo" to bytes(MediaFormat.KEY_HDR_STATIC_INFO),
                "profile" to profile,
                "profileName" to profile?.let { HwProbeRules.profileName(mime, it) },
                "level" to level,
                "levelName" to level?.let { HwProbeRules.levelName(mime, it) },
                "frameRate" to if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                    format.getNumber(MediaFormat.KEY_FRAME_RATE)?.toDouble()
                } else {
                    null
                },
                "csd0" to bytes("csd-0"),
                "csd1" to bytes("csd-1"),
                "csd2" to bytes("csd-2"),
            )
        }

        fun bufferHex(buffer: ByteBuffer?): String? {
            if (buffer == null) return null
            val copy = buffer.duplicate()
            copy.rewind()
            val bytes = ByteArray(copy.remaining())
            copy.get(bytes)
            return HwProbeRules.hex(bytes)
        }
    }
}

/** What `start` was asked for, with its defaults. */
class ProbeArgs(private val m: Map<*, *>) {
    private fun num(key: String): Double? = (m[key] as? Number)?.toDouble()

    val raw: Map<String, Any?> = m.entries.associate { "${it.key}" to it.value }
    val path: String = m["path"] as? String ?: throw IllegalArgumentException("start needs a path")
    val mode: String = (m["mode"] as? String ?: "transcode").also {
        require(it in MODES) { "mode is one of ${MODES.joinToString()}" }
    }
    val label: String = HwProbeRules.safeLabel(
        m["label"] as? String ?: "$mode-${Uri.parse(path).lastPathSegment?.substringBeforeLast('.') ?: "clip"}",
    )
    val mime: String = (m["mime"] as? String ?: "video/hevc").also {
        require(it == "video/hevc" || it == "video/avc") { "mime is video/hevc or video/avc" }
    }
    val profile: String = (m["profile"] as? String ?: "auto").also {
        require(it in PROFILES) { "profile is one of ${PROFILES.joinToString()}" }
    }
    val bitrate: Int = num("bitrate")?.toInt() ?: 12_000_000
    val bitrateMode: String = (m["bitrateMode"] as? String ?: "cbr").also {
        require(it in setOf("cbr", "vbr", "cq")) { "bitrateMode is cbr, vbr or cq" }
    }
    val seconds: Double = num("seconds") ?: 600.0
    val slotSeconds: Double = num("slotSeconds") ?: 10.0
    val requestSyncAt: List<Int> = (m["requestSyncAt"] as? List<*>)?.mapNotNull { (it as? Number)?.toInt() }
        ?: listOf(100, 400, 700)
    val repeat: Int = (num("repeat")?.toInt() ?: 1).coerceAtLeast(1)
    val iFrameInterval: Float = num("iFrameInterval")?.toFloat() ?: if (mode == "perSlot") 3600f else 1f
    val maxBframes: Int = num("maxBframes")?.toInt() ?: 0
    val wakeLock: Boolean = m["wakeLock"] as? Boolean ?: true
    val writeMp4: Boolean = m["writeMp4"] as? Boolean ?: false

    companion object {
        val MODES = setOf("transcode", "decodeOnly", "perSlot", "requestSync")
        val PROFILES = setOf("auto", "main", "main10", "main10hdr10", "high")
    }
}

/** One encoder's output: a whole stream, or one slot of a perSlot run. */
private class EncodeStats(val index: Int) {
    var firstPtsUs: Long? = null
    var lastPtsUs: Long? = null
    var framesIn = 0
    var framesOut = 0
    var setupMs = 0.0
    var startedAtNs = 0L
    var firstOutputMs: Double? = null
    var bytes = 0L
    private val digest = MessageDigest.getInstance("SHA-256")
    val csd = ByteArrayOutputStream()
    var firstIsKey: Boolean? = null
    var keyFrames = 0
    var eosWaitMs: Double? = null
    var eosWaitTimedOut = false
    var drainMs: Double? = null
    var reachedEos = false
    var decoderStrategy: String? = null
    private var hash: String? = null

    fun frameIn(ptsUs: Long) {
        framesIn++
        if (firstPtsUs == null) firstPtsUs = ptsUs
        lastPtsUs = ptsUs
    }

    fun frameOut(data: ByteArray, key: Boolean) {
        if (firstOutputMs == null) firstOutputMs = (System.nanoTime() - startedAtNs) / 1e6
        if (firstIsKey == null) firstIsKey = key
        if (key) keyFrames++
        framesOut++
        bytes += data.size
        digest.update(data)
    }

    fun hash(): String = hash ?: HwProbeRules.hex(digest.digest()).also { hash = it }

    fun csdHash(): String? = csd.toByteArray().takeIf { it.isNotEmpty() }?.let {
        HwProbeRules.hex(MessageDigest.getInstance("SHA-256").digest(it))
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "index" to index,
        "firstPtsUs" to firstPtsUs,
        "lastPtsUs" to lastPtsUs,
        "framesIn" to framesIn,
        "framesOut" to framesOut,
        "setupMs" to setupMs,
        "firstOutputMs" to firstOutputMs,
        "bytes" to bytes,
        "sha256" to hash(),
        "csdSha256" to csdHash(),
        "csdHex" to csd.toByteArray().takeIf { it.isNotEmpty() }?.let { HwProbeRules.hex(it) },
        "firstIsKey" to firstIsKey,
        "keyFrames" to keyFrames,
        "eosWaitMs" to eosWaitMs,
        "eosWaitTimedOut" to eosWaitTimedOut,
        "drainMs" to drainMs,
        "reachedEos" to reachedEos,
        "decoderStrategy" to decoderStrategy,
    )
}

private class Encoder(val codec: MediaCodec, val surface: Surface, val stats: EncodeStats) {
    var eos = false

    fun release() {
        runCatching { codec.stop() }
        runCatching { codec.release() }
        runCatching { surface.release() }
    }
}

/** A slot start found on the input side, waiting for the decoder to reach it. */
private data class Boundary(val ptsUs: Long, val srcUs: Long, val loopOffsetUs: Long)

private class Stopped : RuntimeException("stopped")

/**
 * One `start`: the whole plan, [ProbeArgs.repeat] times, on its own thread.
 * Everything measured is kept when it stops or fails.
 */
@RequiresApi(Build.VERSION_CODES.Q)
private class ProbeRun(private val context: Context, private val args: ProbeArgs) {
    val label = args.label

    @Volatile var running = false
        private set

    @Volatile private var done = false

    @Volatile private var stopRequested = false

    @Volatile private var error: String? = null

    @Volatile private var latestWindow: Map<String, Any?>? = null

    @Volatile private var totals: Map<String, Any?> = emptyMap()

    @Volatile private var codecNames: Map<String, Any?> = emptyMap()

    private val startedAtNs = System.nanoTime()
    private val report = LinkedHashMap<String, Any?>()
    private val windows = mutableListOf<Map<String, Any?>>()
    private val repeats = mutableListOf<Map<String, Any?>>()
    private val repeatHashes = mutableListOf<List<String?>>()
    private val repeatCsds = mutableListOf<List<String?>>()
    private val info = MediaCodec.BufferInfo()

    // Per-repeat state, reset by [runRepeat].
    private var framesInTotal = 0
    private var framesOutTotal = 0
    private var maxOutPtsUs = -1L
    private var firstInPtsUs: Long? = null

    fun start() {
        running = true
        report["label"] = label
        report["args"] = args.raw
        report["system"] = HwProbe.system(context)
        Thread({ work() }, "hwprobe-$label").start()
    }

    fun stop() {
        stopRequested = true
    }

    @Synchronized
    fun report(): Map<String, Any?> = LinkedHashMap(report)

    fun status(): Map<String, Any?> = mapOf(
        "label" to label,
        "running" to running,
        "done" to done,
        "stopped" to stopRequested,
        "error" to error,
        "elapsedS" to (System.nanoTime() - startedAtNs) / 1e9,
        "window" to latestWindow,
        "totals" to totals,
        "codecs" to codecNames,
        "now" to HwProbe.now(context),
    )

    private fun checkStop() {
        if (stopRequested) throw Stopped()
    }

    private fun work() {
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val wake = if (args.wakeLock) power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "xtremio:hwprobe") else null
        try {
            wake?.acquire(6 * 60 * 60 * 1000L)
            for (r in 0 until args.repeat) {
                runRepeat(r)
                if (stopRequested || error != null) break
            }
        } catch (t: Throwable) {
            error = HwProbe.describe(t)
        } finally {
            runCatching { wake?.takeIf { it.isHeld }?.release() }
            synchronized(this) {
                report["windows"] = windows.toList()
                report["repeats"] = repeats.toList()
                report["identity"] = identity()
                report["stopped"] = stopRequested
                report["error"] = error
                report["wallS"] = (System.nanoTime() - startedAtNs) / 1e9
                report["nowAtEnd"] = HwProbe.now(context)
            }
            done = true
            running = false
        }
    }

    private fun identity(): Map<String, Any?> {
        val hashes = HwProbeRules.identity(repeatHashes)
        val csds = HwProbeRules.identity(repeatCsds)
        return mapOf(
            "repeats" to repeatHashes.size,
            "hashMatch" to hashes,
            "csdMatch" to csds,
            "allHashesMatch" to if (repeatHashes.size < 2) null else hashes.all { it == true },
            "allCsdMatch" to if (repeatCsds.size < 2) null else csds.all { it == true },
        )
    }

    // ------------------------------------------------------------ source

    private fun openExtractor(): Pair<MediaExtractor, Int> {
        val extractor = MediaExtractor()
        if (args.path.startsWith("content://")) {
            extractor.setDataSource(context, Uri.parse(args.path), null)
        } else {
            extractor.setDataSource(args.path)
        }
        val track = (0 until extractor.trackCount).firstOrNull {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
        } ?: run {
            extractor.release()
            throw IllegalStateException("no video track in ${args.path}")
        }
        extractor.selectTrack(track)
        return extractor to track
    }

    /**
     * Decodes the start of the clip to buffers, not a surface, until the
     * decoder says what it outputs: the one way to see a P010 decoder
     * output when the track itself says nothing about bit depth.
     */
    private fun probeDecoderOutput(extractor: MediaExtractor, format: MediaFormat): MediaFormat? {
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val decoder = MediaCodec.createDecoderByType(mime)
        try {
            decoder.configure(format, null, null, 0)
            decoder.start()
            val deadline = System.nanoTime() + 3_000_000_000L
            var fed = 0
            while (System.nanoTime() < deadline) {
                checkStop()
                if (fed < 240) {
                    val i = decoder.dequeueInputBuffer(0)
                    if (i >= 0) {
                        val input = decoder.getInputBuffer(i)!!
                        val size = extractor.readSampleData(input, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            fed = Int.MAX_VALUE
                        } else {
                            decoder.queueInputBuffer(i, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                            fed++
                        }
                    }
                }
                val o = decoder.dequeueOutputBuffer(info, 10_000)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) return decoder.outputFormat
                if (o >= 0) {
                    val out = decoder.getOutputFormat(o)
                    decoder.releaseOutputBuffer(o, false)
                    return out
                }
            }
            return null
        } finally {
            runCatching { decoder.stop() }
            runCatching { decoder.release() }
            extractor.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        }
    }

    // --------------------------------------------------------- encoders

    private fun profileValue(tenBit: Boolean): Int {
        val hevc = args.mime == "video/hevc"
        val chosen = if (args.profile == "auto") (if (tenBit) "main10" else "main") else args.profile
        return when {
            hevc && chosen == "main10" -> CodecProfileLevel.HEVCProfileMain10
            hevc && chosen == "main10hdr10" -> CodecProfileLevel.HEVCProfileMain10HDR10
            hevc -> CodecProfileLevel.HEVCProfileMain
            chosen == "high" -> CodecProfileLevel.AVCProfileHigh
            chosen == "main10" || chosen == "main10hdr10" -> CodecProfileLevel.AVCProfileHigh10
            else -> CodecProfileLevel.AVCProfileMain
        }
    }

    private fun encoderFormat(track: MediaFormat, width: Int, height: Int, fps: Float, profile: Int): MediaFormat =
        MediaFormat.createVideoFormat(args.mime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, args.bitrate)
            setInteger(
                MediaFormat.KEY_BITRATE_MODE,
                when (args.bitrateMode) {
                    "vbr" -> MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
                    "cq" -> MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CQ
                    else -> MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
                },
            )
            setFloat(MediaFormat.KEY_FRAME_RATE, fps)
            setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, args.iFrameInterval)
            setInteger(MediaFormat.KEY_PROFILE, profile)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, args.maxBframes)
            setInteger("max-bframes", args.maxBframes)
            for (key in listOf(
                MediaFormat.KEY_COLOR_STANDARD,
                MediaFormat.KEY_COLOR_TRANSFER,
                MediaFormat.KEY_COLOR_RANGE,
            )) {
                if (track.containsKey(key)) setInteger(key, track.getInteger(key))
            }
            if (track.containsKey(MediaFormat.KEY_HDR_STATIC_INFO)) {
                track.getByteBuffer(MediaFormat.KEY_HDR_STATIC_INFO)?.let {
                    setByteBuffer(MediaFormat.KEY_HDR_STATIC_INFO, it.duplicate())
                }
            }
        }

    private fun newEncoder(index: Int, format: MediaFormat): Encoder {
        val t0 = System.nanoTime()
        val codec = MediaCodec.createEncoderByType(args.mime)
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = codec.createInputSurface()
            codec.start()
            val stats = EncodeStats(index)
            stats.setupMs = (System.nanoTime() - t0) / 1e6
            stats.startedAtNs = System.nanoTime()
            return Encoder(codec, surface, stats)
        } catch (t: Throwable) {
            runCatching { codec.release() }
            throw t
        }
    }

    // ------------------------------------------------------------ repeat

    private inner class Repeat(val index: Int) {
        val extractor: MediaExtractor
        val track: MediaFormat
        val srcMime: String
        val width: Int
        val height: Int
        val fps: Float
        val frameUs: Long
        val totalUs = (args.seconds * 1e6).toLong()
        val perSlot = args.mode == "perSlot"
        val decodeOnly = args.mode == "decodeOnly"
        val requestSync = args.mode == "requestSync"
        val tenBitReason: String?
        val profile: Int
        val encFormat: MediaFormat?

        var decoder: MediaCodec? = null
        var encoder: Encoder? = null
        var reader: ImageReader? = null
        var muxer: MediaMuxer? = null
        var muxerTrack = -1
        var mp4Uri: Uri? = null
        var mp4Fd: ParcelFileDescriptor? = null

        val slots = mutableListOf<EncodeStats>()
        val inputs = ArrayList<Long>()
        val outputs = ArrayList<Long>()
        val keyIndices = ArrayList<Int>()
        val syncRequests = ArrayList<Int>()
        val boundaries = ArrayDeque<Boundary>()
        val cutter = HwProbeRules.SlotCutter((args.slotSeconds * 1e6).toLong())

        var loopOffsetUs = 0L
        var slotZeroSeen = false
        var maxSrcUs = -1L
        var loops = 0
        var inputDone = false
        var decoderDone = false
        var emptyOutputs = 0
        var decoderEosSeen = false
        var outIndex = 0
        var released = 0
        var decoderOutputFormat: Map<String, Any?>? = null
        var encoderOutputFormat: Map<String, Any?>? = null
        var decoderProbeFormat: Map<String, Any?>? = null
        var strategy: String? = null
        var setOutputSurfaceError: String? = null
        var decoderRebuilds = 0
        var inputEos: String? = null

        val repeatStartNs = System.nanoTime()
        var windowStartNs = repeatStartNs
        var windowFramesIn = 0
        var windowFramesOut = 0
        var windowMaxPtsUs = -1L

        init {
            val (e, t) = openExtractor()
            extractor = e
            track = extractor.getTrackFormat(t)
            srcMime = track.getString(MediaFormat.KEY_MIME)!!
            width = track.getInteger(MediaFormat.KEY_WIDTH)
            height = track.getInteger(MediaFormat.KEY_HEIGHT)
            fps = if (track.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                track.getNumber(MediaFormat.KEY_FRAME_RATE)?.toFloat()?.takeIf { it > 0 } ?: 24f
            } else {
                24f
            }
            frameUs = (1e6 / fps).toLong()
            val trackProfile = if (track.containsKey(MediaFormat.KEY_PROFILE)) track.getInteger(MediaFormat.KEY_PROFILE) else null
            val transfer = if (track.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
                track.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
            } else {
                null
            }
            val hdr = track.containsKey(MediaFormat.KEY_HDR_STATIC_INFO)
            var reason = HwProbeRules.tenBitReason(srcMime, trackProfile, hdr, transfer, null)
            if (reason == null && args.profile == "auto" && !decodeOnly) {
                val probed = probeDecoderOutput(extractor, track)
                decoderProbeFormat = probed?.let { HwProbe.describeFormat(it) }
                val colorFormat = probed?.takeIf { it.containsKey(MediaFormat.KEY_COLOR_FORMAT) }
                    ?.getInteger(MediaFormat.KEY_COLOR_FORMAT)
                reason = HwProbeRules.tenBitReason(srcMime, null, false, null, colorFormat)
            }
            tenBitReason = reason
            profile = profileValue(reason != null)
            encFormat = if (decodeOnly) null else encoderFormat(track, width, height, fps, profile)
        }

        fun run(): Map<String, Any?> {
            try {
                if (args.writeMp4 && index == 0 && !decodeOnly) openMuxer()
                val surface: Surface
                if (decodeOnly) {
                    val r = ImageReader.newInstance(width, height, ImageFormat.PRIVATE, 4)
                    reader = r
                    surface = r.surface
                } else {
                    val enc = newEncoder(0, encFormat!!)
                    encoder = enc
                    slots.add(enc.stats)
                    surface = enc.surface
                }
                decoder = newDecoder(surface)
                codecNames = mapOf("decoder" to decoder?.name, "encoder" to encoder?.codec?.name)
                loop()
            } catch (_: Stopped) {
                // Kept as measured; the report says it was stopped.
            } catch (t: Throwable) {
                error = HwProbe.describe(t)
            } finally {
                flushWindow(partial = true)
                closeAll()
            }
            return summary()
        }

        fun newDecoder(surface: Surface): MediaCodec {
            val codec = MediaCodec.createDecoderByType(srcMime)
            try {
                codec.configure(track, surface, null, 0)
                codec.start()
            } catch (t: Throwable) {
                runCatching { codec.release() }
                throw t
            }
            return codec
        }

        fun loop() {
            while (true) {
                checkStop()
                var progressed = feed()
                progressed = drainDecoder(if (progressed) 0 else 10_000L) || progressed
                encoder?.let { progressed = drainEncoder(it, 0) || progressed }
                maybeWindow()
                // The decoder's end also finished the encoder, as far as it
                // would go (finishEncoder).
                if (decoderDone) return
            }
        }

        /** Queues one sample into the decoder if it has room. True when it did. */
        fun feed(): Boolean {
            if (inputDone) return false
            val dec = decoder ?: return false
            val i = dec.dequeueInputBuffer(0)
            if (i < 0) return false
            val buffer = dec.getInputBuffer(i)!!
            var size = extractor.readSampleData(buffer, 0)
            if (size < 0) {
                // The clip ran out: go round again with the times moved on,
                // or end the stream when enough has gone in.
                val step = maxSrcUs + frameUs
                if (maxSrcUs >= 0 && loopOffsetUs + step < totalUs) {
                    loopOffsetUs += step
                    loops++
                    maxSrcUs = -1L
                    extractor.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                    size = extractor.readSampleData(buffer, 0)
                }
                if (size < 0) {
                    dec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                    inputEos = "clip end after $loops loops"
                    return true
                }
            }
            val src = extractor.sampleTime
            val pts = src + loopOffsetUs
            if (pts >= totalUs) {
                dec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                inputDone = true
                inputEos = "media time ${args.seconds} s reached after $loops loops"
                return true
            }
            maxSrcUs = maxOf(maxSrcUs, src)
            val sync = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
            // The cutter's first answer is slot 0, which the first encoder
            // already serves; every later one is a cut.
            if (perSlot && cutter.offer(pts, sync)) {
                if (slotZeroSeen) boundaries.addLast(Boundary(pts, src, loopOffsetUs)) else slotZeroSeen = true
            }
            if (firstInPtsUs == null) firstInPtsUs = pts
            dec.queueInputBuffer(i, 0, size, pts, 0)
            extractor.advance()
            return true
        }

        fun drainDecoder(timeoutUs: Long): Boolean {
            val dec = decoder ?: return false
            val o = dec.dequeueOutputBuffer(info, timeoutUs)
            when {
                o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (decoderOutputFormat == null) decoderOutputFormat = HwProbe.describeFormat(dec.outputFormat)
                    return true
                }
                o < 0 -> return false
            }
            val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
            val pts = info.presentationTimeUs
            if (info.size == 0 && !eos) {
                emptyOutputs++
                dec.releaseOutputBuffer(o, false)
                return true
            }
            if (eos && info.size == 0) {
                dec.releaseOutputBuffer(o, false)
                endOfDecoding()
                return true
            }
            if (perSlot) {
                val next = boundaries.firstOrNull()
                if (next != null && pts >= next.ptsUs) {
                    boundaries.removeFirst()
                    if (!cut(next, o)) return true
                }
            }
            if (requestSync && released in args.requestSyncAt) {
                encoder?.codec?.setParameters(
                    Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) },
                )
                syncRequests.add(released)
            }
            if (decodeOnly) {
                dec.releaseOutputBuffer(o, true)
                reader?.acquireLatestImage()?.close()
                countOut(pts)
            } else {
                dec.releaseOutputBuffer(o, pts * 1000)
                encoder?.stats?.frameIn(pts)
            }
            inputs.add(pts)
            released++
            framesInTotal++
            windowFramesIn++
            if (eos) endOfDecoding()
            return true
        }

        fun endOfDecoding() {
            decoderEosSeen = true
            decoderDone = true
            reader?.acquireLatestImage()?.close()
            encoder?.let { finishEncoder(it) }
        }

        fun countOut(pts: Long) {
            framesOutTotal++
            windowFramesOut++
            if (pts > maxOutPtsUs) maxOutPtsUs = pts
        }

        /** Drains what the encoder has. True when anything came out. */
        fun drainEncoder(enc: Encoder, timeoutUs: Long): Boolean {
            var progressed = false
            var wait = timeoutUs
            while (!enc.eos) {
                val o = enc.codec.dequeueOutputBuffer(info, wait)
                wait = 0
                when {
                    o == MediaCodec.INFO_TRY_AGAIN_LATER -> return progressed
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val format = enc.codec.outputFormat
                        if (encoderOutputFormat == null) encoderOutputFormat = HwProbe.describeFormat(format)
                        muxer?.let { m ->
                            if (muxerTrack < 0) {
                                muxerTrack = m.addTrack(format)
                                m.start()
                            }
                        }
                        progressed = true
                        continue
                    }
                    o < 0 -> continue
                }
                progressed = true
                val buffer = enc.codec.getOutputBuffer(o)
                if (buffer != null && info.size > 0) {
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    val data = ByteArray(info.size)
                    buffer.duplicate().get(data)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        enc.stats.csd.write(data)
                    } else {
                        val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                        enc.stats.frameOut(data, key)
                        if (key) keyIndices.add(outIndex)
                        outIndex++
                        outputs.add(info.presentationTimeUs)
                        countOut(info.presentationTimeUs)
                        if (muxer != null && muxerTrack >= 0) muxer!!.writeSampleData(muxerTrack, buffer, info)
                    }
                }
                val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                enc.codec.releaseOutputBuffer(o, false)
                if (eos) {
                    enc.eos = true
                    enc.stats.reachedEos = true
                }
            }
            return progressed
        }

        /**
         * Ends [enc]'s stream. The frames released to its surface may still
         * be on their way, so it first waits (up to a second) for as many
         * frames out as went in, then signals the end and drains.
         */
        fun finishEncoder(enc: Encoder) {
            val waitStart = System.nanoTime()
            while (enc.stats.framesOut < enc.stats.framesIn) {
                checkStop()
                if (System.nanoTime() - waitStart > 1_000_000_000L) {
                    enc.stats.eosWaitTimedOut = true
                    break
                }
                drainEncoder(enc, 10_000)
            }
            enc.stats.eosWaitMs = (System.nanoTime() - waitStart) / 1e6
            val drainStart = System.nanoTime()
            enc.codec.signalEndOfInputStream()
            while (!enc.eos) {
                checkStop()
                if (System.nanoTime() - drainStart > 3_000_000_000L) break
                drainEncoder(enc, 10_000)
            }
            enc.stats.drainMs = (System.nanoTime() - drainStart) / 1e6
        }

        /**
         * A slot starts at [b]: finish the old encoder, start a fresh one, and
         * point the decoder at it. Answers whether the decoder buffer [held]
         * is still there to render (false when the decoder was rebuilt).
         */
        fun cut(b: Boundary, held: Int): Boolean {
            val old = encoder!!
            finishEncoder(old)
            old.release()
            val enc = newEncoder(slots.size, encFormat!!)
            encoder = enc
            slots.add(enc.stats)
            val dec = decoder!!
            if (strategy != "recreateDecoder") {
                try {
                    dec.setOutputSurface(enc.surface)
                    strategy = "setOutputSurface"
                    enc.stats.decoderStrategy = strategy
                    return true
                } catch (t: Throwable) {
                    setOutputSurfaceError = HwProbe.describe(t)
                    strategy = "recreateDecoder"
                }
            }
            // The decoder cannot move to the new surface: build a new one on
            // it and decode again from the slot's sync sample.
            enc.stats.decoderStrategy = strategy
            runCatching { dec.releaseOutputBuffer(held, false) }
            runCatching { dec.stop() }
            runCatching { dec.release() }
            decoder = null
            decoder = newDecoder(enc.surface)
            decoderRebuilds++
            extractor.seekTo(b.srcUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            loopOffsetUs = b.loopOffsetUs
            maxSrcUs = b.srcUs - frameUs
            boundaries.clear()
            cutter.restartAt(b.ptsUs)
            inputDone = false
            codecNames = mapOf("decoder" to decoder?.name, "encoder" to enc.codec.name)
            return false
        }

        // ------------------------------------------------------- windows

        fun maybeWindow() {
            if (System.nanoTime() - windowStartNs >= 5_000_000_000L) flushWindow(partial = false)
        }

        fun flushWindow(partial: Boolean) {
            val nowNs = System.nanoTime()
            val wall = nowNs - windowStartNs
            if (partial && wall < 500_000_000L) return
            val mediaUs = if (windowMaxPtsUs < 0) {
                if (maxOutPtsUs < 0) 0 else maxOutPtsUs - (firstInPtsUs ?: 0) + frameUs
            } else {
                (maxOutPtsUs - windowMaxPtsUs).coerceAtLeast(0)
            }
            val row = mapOf(
                "repeat" to index,
                "tS" to (nowNs - startedAtNs) / 1e9,
                "wallS" to wall / 1e9,
                "partial" to partial,
                "framesIn" to windowFramesIn,
                "framesOut" to windowFramesOut,
                "fps" to windowFramesOut / (wall / 1e9),
                "mediaS" to mediaUs / 1e6,
                "madeX" to HwProbeRules.madeX(mediaUs, wall),
                "now" to HwProbe.now(context),
            )
            windows.add(row)
            latestWindow = row
            windowStartNs = nowNs
            windowFramesIn = 0
            windowFramesOut = 0
            windowMaxPtsUs = maxOutPtsUs
            totals = totalsNow()
        }

        fun totalsNow(): Map<String, Any?> {
            val wall = System.nanoTime() - repeatStartNs
            val mediaUs = if (maxOutPtsUs < 0) 0 else maxOutPtsUs - (firstInPtsUs ?: 0) + frameUs
            return mapOf(
                "repeat" to index,
                "framesIn" to framesInTotal,
                "framesOut" to framesOutTotal,
                "mediaOutS" to mediaUs / 1e6,
                "wallS" to wall / 1e9,
                "madeX" to HwProbeRules.madeX(mediaUs, wall),
            )
        }

        // --------------------------------------------------------- muxer

        fun openMuxer() {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, "$label.mp4")
                put(MediaStore.Downloads.MIME_TYPE, "video/mp4")
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/hwprobe")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore refused the mp4")
            mp4Uri = uri
            val fd = resolver.openFileDescriptor(uri, "rw") ?: throw IllegalStateException("no descriptor for $uri")
            mp4Fd = fd
            muxer = MediaMuxer(fd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        }

        fun closeMuxer(): Map<String, Any?>? {
            val uri = mp4Uri ?: return null
            var problem: String? = null
            muxer?.let { m ->
                try {
                    if (muxerTrack >= 0) m.stop()
                } catch (t: Throwable) {
                    problem = HwProbe.describe(t)
                }
                runCatching { m.release() }
            }
            muxer = null
            runCatching { mp4Fd?.close() }
            val resolver = context.contentResolver
            runCatching {
                resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            }
            var name: String? = null
            var path: String? = null
            var size: Long? = null
            runCatching {
                resolver.query(
                    uri,
                    arrayOf(
                        MediaStore.Downloads.DISPLAY_NAME,
                        MediaStore.Downloads.RELATIVE_PATH,
                        MediaStore.Downloads.SIZE,
                    ),
                    null,
                    null,
                    null,
                )?.use { c ->
                    if (c.moveToFirst()) {
                        name = c.getString(0)
                        path = "/sdcard/${c.getString(1).trimEnd('/')}/${c.getString(0)}"
                        size = c.getLong(2)
                    }
                }
            }
            return mapOf("uri" to uri.toString(), "name" to name, "path" to path, "bytes" to size, "error" to problem)
        }

        fun closeAll() {
            mp4Result = closeMuxer()
            encoder?.release()
            encoder = null
            decoder?.let {
                runCatching { it.stop() }
                runCatching { it.release() }
            }
            decoder = null
            reader?.let { runCatching { it.close() } }
            reader = null
            runCatching { extractor.release() }
        }

        var mp4Result: Map<String, Any?>? = null

        fun summary(): Map<String, Any?> {
            val wall = System.nanoTime() - repeatStartNs
            val full = windows.filter { it["repeat"] == index && it["partial"] == false }
            val setups = slots.drop(1).map { it.setupMs }
            return mapOf(
                "repeat" to index,
                "wallS" to wall / 1e9,
                "totals" to totalsNow(),
                "minWindowMadeX" to full.mapNotNull { it["madeX"] as Double? }.minOrNull(),
                "source" to mapOf(
                    "format" to HwProbe.describeFormat(track),
                    "fps" to fps,
                    "loopStepUs" to if (loops > 0) loopOffsetUs / loops else null,
                    "loops" to loops,
                    "tenBitReason" to tenBitReason,
                    "decoderProbeFormat" to decoderProbeFormat,
                ),
                "profile" to profile,
                "profileName" to HwProbeRules.profileName(args.mime, profile),
                "decoder" to mapOf(
                    "name" to codecNames["decoder"],
                    "outputFormat" to decoderOutputFormat,
                    "emptyOutputs" to emptyOutputs,
                    "sawEndOfStream" to decoderEosSeen,
                    "inputEnd" to inputEos,
                    "rebuilds" to decoderRebuilds,
                ),
                "encoder" to if (decodeOnly) {
                    null
                } else {
                    mapOf(
                        "name" to codecNames["encoder"],
                        "inputFormat" to encFormat.toString(),
                        "outputFormat" to encoderOutputFormat,
                    )
                },
                "pts" to if (decodeOnly) mapOf("in" to inputs.size) else HwProbeRules.comparePts(inputs, outputs),
                "slots" to if (perSlot) slots.map { it.toMap() } else null,
                "stream" to if (!perSlot && !decodeOnly) slots.firstOrNull()?.toMap() else null,
                "slotStrategy" to strategy,
                "setOutputSurfaceError" to setOutputSurfaceError,
                "encoderSetupMsMedian" to HwProbeRules.median(setups),
                "encoderSetupMsFirst" to slots.firstOrNull()?.setupMs,
                "keyFramesAt" to if (keyIndices.size <= 200) keyIndices.toList() else keyIndices.take(200),
                "requestSync" to if (requestSync) HwProbeRules.syncAnswers(syncRequests, keyIndices) else null,
                "mp4" to mp4Result,
            )
        }
    }

    private fun runRepeat(index: Int) {
        framesInTotal = 0
        framesOutTotal = 0
        maxOutPtsUs = -1L
        firstInPtsUs = null
        val repeat = Repeat(index)
        val summary = repeat.run()
        synchronized(this) {
            repeats.add(summary)
            report["repeats"] = repeats.toList()
        }
        if (repeat.decodeOnly) return
        repeatHashes.add(repeat.slots.map { if (it.framesOut > 0) it.hash() else null })
        repeatCsds.add(repeat.slots.map { it.csdHash() })
    }
}
