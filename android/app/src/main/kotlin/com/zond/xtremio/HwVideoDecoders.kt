package com.zond.xtremio

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build

/**
 * Which video codecs this device decodes in hardware, and how large a
 * picture each takes: the `hwVideoDecoders` answer on the `xtremio/device`
 * channel (lib/shell/video_decoders.dart).
 *
 * The player's own surface shows only what a hardware decoder draws, so
 * the player asks this before it sends a film there. The rules are in
 * [answer], with no device in them, so a JVM test reaches them.
 */
object HwVideoDecoders {
    /** The types the player can put on its surface. */
    val MIMES = setOf(
        "video/avc",
        "video/hevc",
        "video/av01",
        "video/x-vnd.on2.vp9",
        "video/x-vnd.on2.vp8",
    )

    /** API 29's own word on where a codec runs; null below it. */
    data class Flags(
        val hardwareAccelerated: Boolean,
        val softwareOnly: Boolean,
        val alias: Boolean,
    )

    /** One codec as MediaCodecList describes it. */
    data class Codec(
        val name: String,
        val isEncoder: Boolean,
        val flags: Flags?,
        /** The largest width and height it takes, per type. */
        val sizes: Map<String, Pair<Int, Int>>,
    )

    /**
     * Whether [codec] runs in hardware. API 29 says so outright. Below it
     * the platform's own software codecs are known by their names.
     */
    fun isHardware(codec: Codec): Boolean {
        val flags = codec.flags
        if (flags != null) return flags.hardwareAccelerated && !flags.softwareOnly && !flags.alias
        return !codec.name.startsWith("OMX.google.", ignoreCase = true) &&
            !codec.name.startsWith("c2.android.", ignoreCase = true)
    }

    /**
     * The channel's answer: per type in [MIMES], the largest width and the
     * largest height any hardware decoder takes. A type no hardware decoder
     * takes is left out.
     */
    fun answer(codecs: List<Codec>): Map<String, Map<String, Int>> {
        val largest = mutableMapOf<String, Pair<Int, Int>>()
        for (codec in codecs) {
            if (codec.isEncoder || !isHardware(codec)) continue
            for ((type, size) in codec.sizes) {
                val mime = type.lowercase()
                if (mime !in MIMES) continue
                val seen = largest[mime]
                largest[mime] = if (seen == null) {
                    size
                } else {
                    maxOf(seen.first, size.first) to maxOf(seen.second, size.second)
                }
            }
        }
        return largest.mapValues { (_, size) ->
            mapOf("maxWidth" to size.first, "maxHeight" to size.second)
        }
    }

    /** [answer] for this device's codecs. */
    fun onThisDevice(): Map<String, Map<String, Int>> =
        answer(MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.map(::codecOf))

    private fun codecOf(info: MediaCodecInfo): Codec {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            Flags(info.isHardwareAccelerated, info.isSoftwareOnly, info.isAlias)
        } else {
            null
        }
        val sizes = mutableMapOf<String, Pair<Int, Int>>()
        if (!info.isEncoder) {
            for (type in info.supportedTypes) {
                if (type.lowercase() !in MIMES) continue
                // A codec can refuse to describe a type it lists.
                val video = runCatching { info.getCapabilitiesForType(type).videoCapabilities }
                    .getOrNull() ?: continue
                sizes[type] = video.supportedWidths.upper to video.supportedHeights.upper
            }
        }
        return Codec(info.name, info.isEncoder, flags, sizes)
    }
}
