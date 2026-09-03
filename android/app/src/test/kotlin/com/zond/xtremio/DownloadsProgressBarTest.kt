package com.zond.xtremio

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The one piece of the downloads service with no Android in it, so the one
 * piece a JVM test can reach. Everything else -- the notification, the
 * service's lifecycle, the permission dialog -- needs a device.
 */
class DownloadsProgressBarTest {
    @Test
    fun `a percentage becomes a bar of a hundred`() {
        assertEquals(
            DownloadsProgressBar(100, 17, indeterminate = false),
            DownloadsProgressBar.of(17),
        )
    }

    @Test
    fun `nothing known makes the bar endless`() {
        assertEquals(
            DownloadsProgressBar(100, 0, indeterminate = true),
            DownloadsProgressBar.of(-1),
        )
    }

    @Test
    fun `a percentage past its ends is clamped, not drawn`() {
        assertEquals(100, DownloadsProgressBar.of(140).current)
        assertEquals(0, DownloadsProgressBar.of(0).current)
    }
}
