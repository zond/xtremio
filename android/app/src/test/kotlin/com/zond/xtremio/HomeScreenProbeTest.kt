package com.zond.xtremio

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The home-screen probe's part with no Android in it: which rows it takes
 * out and what it says. The entry's ContentValues come from
 * WatchNextProgram.Builder, which needs Android, so they are not here.
 */
class HomeScreenProbeTest {
    @Test
    fun `remove takes only the rows the probe put there`() {
        assertEquals(
            listOf(3L, 9L),
            HomeScreenProbe.probeRows(
                listOf(
                    3L to "xtremio-probe",
                    4L to "tt0111161",
                    5L to null,
                    9L to "xtremio-probe",
                ),
            ),
        )
    }

    @Test
    fun `the answers say what happened`() {
        assertEquals("Inserted the probe as Watch Next row 42.", HomeScreenProbe.inserted(42))
        assertEquals("There was no probe to remove.", HomeScreenProbe.removed(0))
        assertEquals("Removed the probe.", HomeScreenProbe.removed(1))
        assertEquals("Removed 2 probe rows.", HomeScreenProbe.removed(2))
        assertEquals(
            "Could not insert the probe: SecurityException: no write",
            HomeScreenProbe.failed("insert", SecurityException("no write")),
        )
        assertEquals(
            "Could not remove the probe: IllegalStateException",
            HomeScreenProbe.failed("remove", IllegalStateException()),
        )
    }
}
