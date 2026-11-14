package com.zond.xtremio

import org.junit.Assert.assertEquals
import org.junit.Test

/** Which decoders the `hwVideoDecoders` answer counts (HwVideoDecoders.kt). */
class HwVideoDecodersTest {
    private val hardware = HwVideoDecoders.Flags(hardwareAccelerated = true, softwareOnly = false, alias = false)
    private val software = HwVideoDecoders.Flags(hardwareAccelerated = false, softwareOnly = true, alias = false)

    private fun decoder(
        name: String,
        flags: HwVideoDecoders.Flags?,
        vararg sizes: Pair<String, Pair<Int, Int>>,
        isEncoder: Boolean = false,
    ) = HwVideoDecoders.Codec(name, isEncoder, flags, sizes.toMap())

    @Test
    fun `a TV whose only AV1 decoder is software has no AV1`() {
        val answer = HwVideoDecoders.answer(
            listOf(
                decoder("c2.amlogic.hevc.decoder", hardware, "video/hevc" to (4096 to 2304)),
                decoder("c2.android.av1.decoder", software, "video/av01" to (4096 to 4096)),
            ),
        )
        assertEquals(mapOf("video/hevc" to mapOf("maxWidth" to 4096, "maxHeight" to 2304)), answer)
    }

    @Test
    fun `an alias and an encoder are not counted`() {
        val alias = HwVideoDecoders.Flags(hardwareAccelerated = true, softwareOnly = false, alias = true)
        val answer = HwVideoDecoders.answer(
            listOf(
                decoder("OMX.amlogic.hevc.decoder.awesome", alias, "video/hevc" to (4096 to 2304)),
                decoder("c2.amlogic.avc.encoder", hardware, "video/avc" to (1920 to 1080), isEncoder = true),
            ),
        )
        assertEquals(emptyMap<String, Map<String, Int>>(), answer)
    }

    @Test
    fun `below API 29 the platform's software decoders are known by name`() {
        val answer = HwVideoDecoders.answer(
            listOf(
                decoder("OMX.google.h264.decoder", null, "video/avc" to (4096 to 4096)),
                decoder("c2.android.vp9.decoder", null, "video/x-vnd.on2.vp9" to (4096 to 4096)),
                decoder("OMX.MTK.VIDEO.DECODER.AVC", null, "video/avc" to (1920 to 1088)),
            ),
        )
        assertEquals(mapOf("video/avc" to mapOf("maxWidth" to 1920, "maxHeight" to 1088)), answer)
    }

    @Test
    fun `the largest width and height across decoders, for the player's types only`() {
        val answer = HwVideoDecoders.answer(
            listOf(
                decoder("c2.vendor.avc.decoder", hardware, "video/avc" to (1920 to 1088)),
                decoder("c2.vendor.avc.decoder.wide", hardware, "VIDEO/AVC" to (4096 to 1080)),
                decoder("c2.vendor.mpeg2.decoder", hardware, "video/mpeg2" to (1920 to 1088)),
            ),
        )
        assertEquals(mapOf("video/avc" to mapOf("maxWidth" to 4096, "maxHeight" to 1088)), answer)
    }
}
