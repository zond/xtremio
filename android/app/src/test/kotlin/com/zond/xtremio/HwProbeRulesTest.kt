package com.zond.xtremio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The codec probe's rules with no device in them (HwProbeRules.kt). The
 * codecs themselves need the phone (docs/DRIVING.md, "The codec probe").
 */
class HwProbeRulesTest {
    private val s = 1_000_000L

    @Test
    fun `a slot starts at the first sync sample a slot length after the last start`() {
        // Key frames every 4 s, so a 10 s slot has to wait for 12 s.
        val samples = (0..30).map { t -> t * s to (t % 4 == 0) }
        assertEquals(listOf(0L, 12 * s, 24 * s), HwProbeRules.slotStarts(samples, 10 * s))
    }

    @Test
    fun `a sync sample exactly a slot length on starts the slot`() {
        val samples = listOf(0L to true, 5 * s to true, 10 * s to true, 15 * s to false, 20 * s to true)
        assertEquals(listOf(0L, 10 * s, 20 * s), HwProbeRules.slotStarts(samples, 10 * s))
    }

    @Test
    fun `samples before the first sync sample start nothing`() {
        val samples = listOf(0L to false, 1 * s to false, 2 * s to true, 11 * s to true, 12 * s to true)
        assertEquals(listOf(2 * s, 12 * s), HwProbeRules.slotStarts(samples, 10 * s))
    }

    @Test
    fun `a rebuilt decoder carries on from the slot it restarted at`() {
        val cutter = HwProbeRules.SlotCutter(10 * s)
        cutter.offer(0, true)
        cutter.offer(10 * s, true)
        cutter.offer(20 * s, true)
        // The decoder is rebuilt at 10 s and feeds that sample again.
        cutter.restartAt(10 * s)
        assertEquals(false, cutter.offer(10 * s, true))
        assertEquals(false, cutter.offer(15 * s, true))
        assertEquals(true, cutter.offer(20 * s, true))
    }

    @Test
    fun `pts that came out as they went in compare clean`() {
        val pts = listOf(0L, 41_666, 83_333)
        val answer = HwProbeRules.comparePts(pts, pts.reversed())
        assertEquals(0, answer["outNotIn"])
        assertEquals(0, answer["inNeverOut"])
        assertEquals(emptyList<Any>(), answer["firstDiffs"])
    }

    @Test
    fun `a dropped frame and a moved one are both counted`() {
        val inputs = listOf(0L, 100, 200, 300)
        val outputs = listOf(0L, 100, 250)
        val answer = HwProbeRules.comparePts(inputs, outputs)
        assertEquals(4, answer["in"])
        assertEquals(3, answer["out"])
        assertEquals(1, answer["outNotIn"])
        assertEquals(2, answer["inNeverOut"])
        assertEquals(
            listOf(
                mapOf<String, Any?>("index" to 2, "in" to 200L, "out" to 250L),
                mapOf<String, Any?>("index" to 3, "in" to 300L, "out" to null),
            ),
            answer["firstDiffs"],
        )
    }

    @Test
    fun `a repeated pts is matched once per copy`() {
        val answer = HwProbeRules.comparePts(listOf(5L, 5L), listOf(5L, 5L, 5L))
        assertEquals(1, answer["outNotIn"])
        assertEquals(0, answer["inNeverOut"])
    }

    @Test
    fun `a sync request is answered by the next key frame at or after it`() {
        val answers = HwProbeRules.syncAnswers(listOf(100, 400, 700), listOf(0, 101, 400, 650))
        assertEquals(listOf(101, 400, null), answers.map { it["keyAt"] })
        assertEquals(listOf(1, 0, null), answers.map { it["delta"] })
    }

    @Test
    fun `profiles and levels are named from the platform's constants`() {
        assertEquals("HEVCProfileMain10", HwProbeRules.profileName("video/hevc", 2))
        assertEquals("HEVCProfileMain10HDR10", HwProbeRules.profileName("video/hevc", 0x1000))
        assertEquals("AV1ProfileMain10", HwProbeRules.profileName("video/av01", 2))
        assertEquals("AVCProfileHigh", HwProbeRules.profileName("video/avc", 8))
        assertEquals("VP9Profile2", HwProbeRules.profileName("video/x-vnd.on2.vp9", 4))
        assertEquals("DolbyVisionProfileDvheSt", HwProbeRules.profileName("video/dolby-vision", 0x100))
        assertEquals("HEVCMainTierLevel51", HwProbeRules.levelName("video/hevc", 0x10000))
        assertEquals("HEVCHighTierLevel51", HwProbeRules.levelName("video/hevc", 0x20000))
        assertEquals("AVCLevel41", HwProbeRules.levelName("video/avc", 0x1000))
        assertNull(HwProbeRules.profileName("video/unknown", 1))
        assertNull(HwProbeRules.profileName("video/hevc", 0x7777))
    }

    @Test
    fun `colour formats are named, P010 and the surface among them`() {
        assertEquals("COLOR_FormatYUVP010", HwProbeRules.colorFormatName(54))
        assertEquals("COLOR_FormatSurface", HwProbeRules.colorFormatName(0x7F000789))
        assertEquals("COLOR_FormatYUV420Flexible", HwProbeRules.colorFormatName(0x7F420888))
    }

    @Test
    fun `ten bit is read from the profile, HDR keys, or the decoder's output`() {
        assertEquals("track profile HEVCProfileMain10", HwProbeRules.tenBitReason("video/hevc", 2, false, null, null))
        assertEquals("track profile AV1ProfileMain10", HwProbeRules.tenBitReason("video/av01", 2, false, null, null))
        // AV1's Main10 value is HEVC's Main10 value too, but Main8 is 1.
        assertNull(HwProbeRules.tenBitReason("video/av01", 1, false, null, null))
        assertEquals("track has hdr-static-info", HwProbeRules.tenBitReason("video/hevc", null, true, null, null))
        assertEquals("track colour transfer 6", HwProbeRules.tenBitReason("video/hevc", 1, false, 6, null))
        assertEquals(
            "decoder outputs COLOR_FormatYUVP010",
            HwProbeRules.tenBitReason("video/hevc", null, false, 3, 54),
        )
        assertNull(HwProbeRules.tenBitReason("video/hevc", 1, false, 3, 0x7F420888))
    }

    @Test
    fun `times real time is media seconds over wall seconds`() {
        assertEquals(2.0, HwProbeRules.madeX(10 * s, 5_000_000_000L)!!, 1e-9)
        assertNull(HwProbeRules.madeX(10 * s, 0))
    }

    @Test
    fun `median, label and identity`() {
        assertEquals(2.0, HwProbeRules.median(listOf(3.0, 1.0, 2.0))!!, 0.0)
        assertEquals(2.5, HwProbeRules.median(listOf(4.0, 1.0, 2.0, 3.0))!!, 0.0)
        assertNull(HwProbeRules.median(emptyList()))
        assertEquals("4K_HDR_main10.v2", HwProbeRules.safeLabel("4K HDR/main10.v2"))
        assertEquals(
            listOf(true, false, false),
            HwProbeRules.identity(listOf(listOf("a", "b", "c"), listOf("a", "x"))),
        )
        assertEquals(listOf<Boolean?>(null), HwProbeRules.identity(listOf(listOf("a"))))
    }

    @Test
    fun `hex is lower case, two digits a byte`() {
        assertEquals("00ff10", HwProbeRules.hex(byteArrayOf(0, -1, 16)))
    }
}
