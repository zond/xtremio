package com.zond.xtremio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The one piece of the frame-rate matching with no Android in it, so the
 * one piece a JVM test can reach. The surface, the window and the display
 * itself need a device (ANDROID.md, "Telling the television what rate the
 * film is").
 *
 * The modes are the owner's, read off `dumpsys display` on a Chromecast
 * with Google TV driving an Acer 1080p projector, which is the panel the
 * 560 dropped frames were counted on.
 */
class FrameRateModeTest {
    private val sixtyHz = FrameRateMode(1074, 1920, 1080, 59.94f)
    private val twentyFourish = FrameRateMode(1082, 1920, 1080, 23.976f)
    private val twentyFour = FrameRateMode(1083, 1920, 1080, 24.0f)
    private val fiftyHz = FrameRateMode(1080, 1920, 1080, 50.0f)
    private val projector = listOf(sixtyHz, fiftyHz, twentyFourish, twentyFour)

    @Test
    fun `a film gets the mode cut for it`() {
        assertEquals(
            twentyFourish.id as Int?,
            FrameRateMode.matching(23.976, sixtyHz, projector),
        )
    }

    @Test
    fun `24 Hz is close enough when 23_976 is not offered`() {
        assertEquals(
            twentyFour.id as Int?,
            FrameRateMode.matching(23.976, sixtyHz, listOf(sixtyHz, fiftyHz, twentyFour)),
        )
    }

    @Test
    fun `a whole multiple is a match, and the film's own rate is the better one`() {
        val doubled = FrameRateMode(1090, 1920, 1080, 47.952f)
        // Showing every frame twice is just as even, so 47.952 Hz is taken
        // when it is all there is...
        assertEquals(
            doubled.id as Int?,
            FrameRateMode.matching(23.976, sixtyHz, listOf(sixtyHz, doubled)),
        )
        // ...and passed over for the rate the film actually is.
        assertEquals(
            twentyFourish.id as Int?,
            FrameRateMode.matching(23.976, sixtyHz, listOf(sixtyHz, twentyFourish, doubled)),
        )
    }

    @Test
    fun `PAL video takes 50 Hz and NTSC video stays where it is`() {
        assertEquals(fiftyHz.id as Int?, FrameRateMode.matching(25.0, sixtyHz, projector))
        // 59.94 Hz is exactly twice 29.97: the mode already running is the
        // right one, and there is nothing to ask for.
        assertNull(FrameRateMode.matching(29.97, sixtyHz, projector))
    }

    @Test
    fun `an uneven cadence is not a match`() {
        // 59.94 over 23.976 is 2.5 -- the 3:2 pulldown that drops frames --
        // and 50 Hz over it is 2.085. With nothing else on offer the
        // display is left alone rather than switched to another wrong one.
        assertNull(FrameRateMode.matching(23.976, sixtyHz, listOf(sixtyHz, fiftyHz)))
    }

    @Test
    fun `a mode of another size is not offered whatever its rate`() {
        val smaller = FrameRateMode(1200, 1280, 720, 23.976f)
        assertNull(FrameRateMode.matching(23.976, sixtyHz, listOf(sixtyHz, smaller)))
    }

    @Test
    fun `a rate that is no rate asks for nothing`() {
        assertNull(FrameRateMode.matching(0.0, sixtyHz, projector))
        assertNull(FrameRateMode.matching(-24.0, sixtyHz, projector))
        assertNull(FrameRateMode.matching(Double.NaN, sixtyHz, projector))
    }

    @Test
    fun `a rate no content has is not believed`() {
        // `container-fps` is a claim computed from the track's own timing,
        // so a Matroska file whose `default_duration` says one millisecond
        // reports 1000 fps. The floor is the same damage the other way: a
        // container declaring 1 fps finds 50 Hz an exact whole multiple
        // and would switch the panel for it.
        assertFalse(FrameRateMode.plausible(1000.0))
        assertFalse(FrameRateMode.plausible(1.0))
        assertFalse(FrameRateMode.plausible(0.0))
        assertFalse(FrameRateMode.plausible(-24.0))
        assertFalse(FrameRateMode.plausible(Double.NaN))
        assertFalse(FrameRateMode.plausible(Double.POSITIVE_INFINITY))
        assertNull(FrameRateMode.matching(1000.0, sixtyHz, projector))
        assertNull(FrameRateMode.matching(1.0, sixtyHz, projector))

        // Everything real content declares is inside it, film at the
        // bottom and NTSC-pulled 120 at the top.
        for (rate in listOf(23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 119.88, 120.0)) {
            assertTrue("$rate is a rate content really declares", FrameRateMode.plausible(rate))
        }
    }

    @Test
    fun `a display slower than the content has no multiple to offer`() {
        assertNull(FrameRateMode.matching(60.0, twentyFourish, listOf(twentyFourish, twentyFour)))
    }
}
