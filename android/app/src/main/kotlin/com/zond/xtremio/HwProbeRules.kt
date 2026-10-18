package com.zond.xtremio

import android.media.MediaCodecInfo.CodecCapabilities
import android.media.MediaCodecInfo.CodecProfileLevel
import java.nio.ByteBuffer

/**
 * The parts of the codec probe (HwProbe.kt) with no device in them, so a
 * JVM test can reach them: names for the codec constants, the slot rule,
 * the pts comparison and the arithmetic the report is made of.
 *
 * Like the probe, this goes when the real conversion is built.
 */
object HwProbeRules {
    // ------------------------------------------------------------ names

    /** The field-name prefixes of [CodecProfileLevel] for each type. */
    private val profilePrefixes = mapOf(
        "video/avc" to listOf("AVCProfile"),
        "video/hevc" to listOf("HEVCProfile"),
        "video/av01" to listOf("AV1Profile"),
        "video/x-vnd.on2.vp9" to listOf("VP9Profile"),
        "video/x-vnd.on2.vp8" to listOf("VP8Profile"),
        "video/dolby-vision" to listOf("DolbyVisionProfile"),
        "video/mp4v-es" to listOf("MPEG4Profile"),
        "video/3gpp" to listOf("H263Profile"),
        "video/mpeg2" to listOf("MPEG2Profile"),
    )

    private val levelPrefixes = mapOf(
        "video/avc" to listOf("AVCLevel"),
        "video/hevc" to listOf("HEVCMainTierLevel", "HEVCHighTierLevel"),
        "video/av01" to listOf("AV1Level"),
        "video/x-vnd.on2.vp9" to listOf("VP9Level"),
        "video/x-vnd.on2.vp8" to listOf("VP8Level"),
        "video/dolby-vision" to listOf("DolbyVisionLevel"),
        "video/mp4v-es" to listOf("MPEG4Level"),
        "video/3gpp" to listOf("H263Level"),
        "video/mpeg2" to listOf("MPEG2Level"),
    )

    /** Value to field name, for the static int fields of [type] starting with [prefixes]. */
    private fun constants(type: Class<*>, prefixes: List<String>): Map<Int, String> {
        val out = LinkedHashMap<Int, String>()
        for (field in type.fields) {
            if (field.type != Int::class.javaPrimitiveType) continue
            if (prefixes.none { field.name.startsWith(it) }) continue
            if (!java.lang.reflect.Modifier.isStatic(field.modifiers)) continue
            val value = runCatching { field.getInt(null) }.getOrNull() ?: continue
            out.putIfAbsent(value, field.name)
        }
        return out
    }

    private val profileNames = HashMap<String, Map<Int, String>>()
    private val levelNames = HashMap<String, Map<Int, String>>()

    /** `HEVCProfileMain10` for (`video/hevc`, 2); null for a type or value it does not know. */
    @Synchronized
    fun profileName(mime: String, profile: Int): String? {
        val prefixes = profilePrefixes[mime.lowercase()] ?: return null
        return profileNames.getOrPut(mime.lowercase()) {
            constants(CodecProfileLevel::class.java, prefixes)
        }[profile]
    }

    /** `HEVCMainTierLevel51` for (`video/hevc`, 0x10000). */
    @Synchronized
    fun levelName(mime: String, level: Int): String? {
        val prefixes = levelPrefixes[mime.lowercase()] ?: return null
        return levelNames.getOrPut(mime.lowercase()) {
            constants(CodecProfileLevel::class.java, prefixes)
        }[level]
    }

    private val colorFormatNames: Map<Int, String> by lazy {
        constants(CodecCapabilities::class.java, listOf("COLOR_"))
    }

    /** `COLOR_FormatYUVP010` for 54, `COLOR_FormatSurface` for 0x7F000789. */
    fun colorFormatName(format: Int): String? = colorFormatNames[format]

    const val COLOR_P010 = 54
    const val COLOR_SURFACE = 0x7F000789

    fun thermalName(status: Int): String = when (status) {
        0 -> "none"
        1 -> "light"
        2 -> "moderate"
        3 -> "severe"
        4 -> "critical"
        5 -> "emergency"
        6 -> "shutdown"
        else -> "unknown($status)"
    }

    /** `BatteryManager.EXTRA_PLUGGED` as a word. */
    fun pluggedName(plugged: Int): String = when (plugged) {
        0 -> "none"
        1 -> "ac"
        2 -> "usb"
        4 -> "wireless"
        8 -> "dock"
        else -> "other($plugged)"
    }

    // ------------------------------------------------------- 10-bit rule

    private val tenBitProfiles = mapOf(
        "video/hevc" to setOf(
            CodecProfileLevel.HEVCProfileMain10,
            CodecProfileLevel.HEVCProfileMain10HDR10,
            CodecProfileLevel.HEVCProfileMain10HDR10Plus,
        ),
        "video/av01" to setOf(
            CodecProfileLevel.AV1ProfileMain10,
            CodecProfileLevel.AV1ProfileMain10HDR10,
            CodecProfileLevel.AV1ProfileMain10HDR10Plus,
        ),
        "video/x-vnd.on2.vp9" to setOf(
            CodecProfileLevel.VP9Profile2,
            CodecProfileLevel.VP9Profile3,
            CodecProfileLevel.VP9Profile2HDR,
            CodecProfileLevel.VP9Profile3HDR,
            CodecProfileLevel.VP9Profile2HDR10Plus,
            CodecProfileLevel.VP9Profile3HDR10Plus,
        ),
        "video/avc" to setOf(
            CodecProfileLevel.AVCProfileHigh10,
            CodecProfileLevel.AVCProfileHigh422,
            CodecProfileLevel.AVCProfileHigh444,
        ),
    )

    /** `MediaFormat.COLOR_TRANSFER_ST2084` and `COLOR_TRANSFER_HLG`. */
    private val hdrTransfers = setOf(6, 7)

    /**
     * Why the source is 10-bit, or null when nothing says so. `auto` picks
     * Main10 exactly when this answers something.
     */
    fun tenBitReason(
        mime: String,
        profile: Int?,
        hasHdrStaticInfo: Boolean,
        transfer: Int?,
        decoderColorFormat: Int?,
    ): String? = when {
        profile != null && profile in tenBitProfiles[mime.lowercase()].orEmpty() ->
            "track profile ${profileName(mime, profile) ?: profile}"
        mime.lowercase() == "video/dolby-vision" -> "Dolby Vision track"
        hasHdrStaticInfo -> "track has hdr-static-info"
        transfer != null && transfer in hdrTransfers -> "track colour transfer $transfer"
        decoderColorFormat == COLOR_P010 -> "decoder outputs COLOR_FormatYUVP010"
        else -> null
    }

    // ------------------------------------------------------- slot rule

    /**
     * Where slots start, fed the source's samples in decode order: a slot
     * starts at the first sync sample at or after the previous start plus
     * [slotUs]. The first sync sample starts slot 0.
     */
    class SlotCutter(private val slotUs: Long) {
        private var lastUs: Long? = null

        /** True when the sample at [timeUs] starts a new slot (slot 0 too). */
        fun offer(timeUs: Long, sync: Boolean): Boolean {
            if (!sync) return false
            val last = lastUs
            if (last != null && timeUs < last + slotUs) return false
            lastUs = timeUs
            return true
        }

        /** The decoder was rebuilt at the slot starting at [timeUs]; carry on from there. */
        fun restartAt(timeUs: Long) {
            lastUs = timeUs
        }
    }

    /** [SlotCutter] over a whole list of (time, sync) samples. */
    fun slotStarts(samples: List<Pair<Long, Boolean>>, slotUs: Long): List<Long> {
        val cutter = SlotCutter(slotUs)
        return samples.filter { (t, sync) -> cutter.offer(t, sync) }.map { it.first }
    }

    // ------------------------------------------------- pts bookkeeping

    /**
     * Every pts released to the encoder's surface against every pts the
     * encoder put out: counts, the ones on one side only, and the first ten
     * places where the sorted lists disagree.
     */
    fun comparePts(inputs: List<Long>, outputs: List<Long>): Map<String, Any?> {
        val remaining = HashMap<Long, Int>()
        for (p in inputs) remaining.merge(p, 1, Int::plus)
        var outNotIn = 0
        for (p in outputs) {
            val n = remaining[p]
            if (n == null || n == 0) outNotIn++ else remaining[p] = n - 1
        }
        val inNeverOut = remaining.values.sum()
        val a = inputs.sorted()
        val b = outputs.sorted()
        val diffs = mutableListOf<Map<String, Any?>>()
        var i = 0
        while (diffs.size < 10 && i < maxOf(a.size, b.size)) {
            val x = a.getOrNull(i)
            val y = b.getOrNull(i)
            if (x != y) diffs.add(mapOf("index" to i, "in" to x, "out" to y))
            i++
        }
        return mapOf(
            "in" to inputs.size,
            "out" to outputs.size,
            "outNotIn" to outNotIn,
            "inNeverOut" to inNeverOut,
            "firstDiffs" to diffs,
        )
    }

    // ------------------------------------------------ request-sync rule

    /**
     * For each frame index a sync frame was asked for at, the index of the
     * next key frame at or after it among [keyIndices], and how many frames
     * later that was. Both are null when no key frame followed.
     */
    fun syncAnswers(requests: List<Int>, keyIndices: List<Int>): List<Map<String, Any?>> {
        val keys = keyIndices.sorted()
        return requests.map { r ->
            val k = keys.firstOrNull { it >= r }
            mapOf("requestedAt" to r, "keyAt" to k, "delta" to k?.let { it - r })
        }
    }

    // ------------------------------------------------------- plane copy

    /**
     * One plane of a picture in a buffer: the index of its first sample, the
     * bytes from one row to the next, and the bytes from one sample to the
     * next. An interleaved chroma plane is two of these, U and V, each with a
     * pixel stride of twice the sample size.
     */
    class Plane(val buffer: ByteBuffer, val offset: Int, val rowStride: Int, val pixelStride: Int)

    /**
     * Copies [width] samples of [bytesPerSample] bytes on each of [height]
     * rows from [src] to [dst]. Each side keeps its own strides. The bytes
     * between samples on the destination side are left as they were, so U
     * and V of an interleaved plane can be copied one after the other. The
     * buffers' positions and limits are not touched.
     */
    fun copyPlane(src: Plane, dst: Plane, width: Int, height: Int, bytesPerSample: Int) {
        if (width <= 0 || height <= 0) return
        val srcSpan = (width - 1) * src.pixelStride + bytesPerSample
        val dstSpan = (width - 1) * dst.pixelStride + bytesPerSample
        val from = src.buffer.duplicate()
        from.clear()
        val to = dst.buffer.duplicate()
        to.clear()
        val packed = src.pixelStride == bytesPerSample && dst.pixelStride == bytesPerSample
        val srcRow = ByteArray(srcSpan)
        val dstRow = if (packed) srcRow else ByteArray(dstSpan)
        for (y in 0 until height) {
            from.position(src.offset + y * src.rowStride)
            from.get(srcRow, 0, srcSpan)
            val at = dst.offset + y * dst.rowStride
            to.position(at)
            if (!packed) {
                to.get(dstRow, 0, dstSpan)
                to.position(at)
                for (x in 0 until width) {
                    val s = x * src.pixelStride
                    val d = x * dst.pixelStride
                    for (b in 0 until bytesPerSample) dstRow[d + b] = srcRow[s + b]
                }
            }
            to.put(dstRow, 0, dstSpan)
        }
    }

    /**
     * The bytes from one row of a P010 buffer to the next, from a format's
     * `stride`. Codecs differ on whether that counts bytes or samples, so a
     * stride shorter than two bytes a sample is taken as samples. No stride
     * means rows packed tight.
     */
    fun p010RowBytes(stride: Int?, width: Int): Int = when {
        stride == null || stride <= 0 -> width * 2
        stride < width * 2 -> stride * 2
        else -> stride
    }

    // ---------------------------------------------------------- numbers

    /** Media seconds made per wall second; null when no time passed. */
    fun madeX(mediaUs: Long, wallNs: Long): Double? =
        if (wallNs <= 0) null else (mediaUs / 1e6) / (wallNs / 1e9)

    fun median(values: List<Double>): Double? {
        if (values.isEmpty()) return null
        val s = values.sorted()
        val mid = s.size / 2
        return if (s.size % 2 == 1) s[mid] else (s[mid - 1] + s[mid]) / 2
    }

    /** A label as a file name: letters, digits, dot, dash and underscore. */
    fun safeLabel(label: String): String =
        label.replace(Regex("[^A-Za-z0-9._-]"), "_").trim('.').ifEmpty { "run" }

    /**
     * Whether every repeat made the same thing: [runs] holds one list per
     * repeat, one hash per slot (one entry for a whole stream). A slot
     * missing from a repeat (a stopped run) does not match.
     */
    fun identity(runs: List<List<String?>>): List<Boolean?> {
        if (runs.size < 2) return runs.firstOrNull()?.map { null } ?: emptyList()
        val n = runs.maxOf { it.size }
        return (0 until n).map { i ->
            val first = runs[0].getOrNull(i)
            first != null && runs.all { it.getOrNull(i) == first }
        }
    }

    fun hex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xff
            out.append("0123456789abcdef"[v ushr 4]).append("0123456789abcdef"[v and 0xf])
        }
        return out.toString()
    }
}
