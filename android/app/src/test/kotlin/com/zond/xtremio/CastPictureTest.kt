package com.zond.xtremio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * What a receiver's `videoInfo` becomes for Dart: the part of
 * CastPictureChannel with no Android in it. The listener itself needs a
 * receiver.
 */
class CastPictureTest {
    @Test
    fun `a picture is its size and its HDR type by name`() {
        // What the Chromecast with Google TV 4K reported for an H.264 MP4.
        assertEquals(
            mapOf("width" to 1280, "height" to 720, "hdr" to "sdr"),
            CastPicture.of(1280, 720, 1),
        )
        assertEquals("hdr10", CastPicture.of(3840, 2160, 2)?.get("hdr"))
        assertEquals("dolbyVision", CastPicture.of(3840, 2160, 3)?.get("hdr"))
        assertEquals("hdr", CastPicture.of(3840, 2160, 4)?.get("hdr"))
        assertEquals("unknown", CastPicture.of(1920, 1080, 0)?.get("hdr"))
    }

    @Test
    fun `a picture with no size is no picture`() {
        assertNull(CastPicture.of(0, 0, 1))
        assertNull(CastPicture.of(1280, 0, 1))
    }
}
