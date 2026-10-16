package com.zond.xtremio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The expanded downloads notification, laid out from what Dart sends. */
class DownloadsNotificationTextTest {
    private val film = DownloadBlock(
        "A Film",
        listOf(
            "Downloading 32%",
            "1.2 MB/s · connected 14 · seeds 137 · swarm 539",
            "612 MB of 1.9 GB",
        ),
    )
    private val episode = DownloadBlock(
        "A Show: S1E1 · Pilot",
        listOf("Finding peers", "No peers found yet", "0 B of 1.2 GB"),
    )

    @Test
    fun `one download is its lines, without its title`() {
        assertEquals(
            "Downloading 32%\n" +
                "1.2 MB/s · connected 14 · seeds 137 · swarm 539\n" +
                "612 MB of 1.9 GB",
            DownloadsNotificationText.expanded(listOf(film)),
        )
    }

    @Test
    fun `several are a block each, headed by the title`() {
        assertEquals(
            "A Film\n" +
                "Downloading 32%\n" +
                "1.2 MB/s · connected 14 · seeds 137 · swarm 539\n" +
                "612 MB of 1.9 GB\n" +
                "\n" +
                "A Show: S1E1 · Pilot\n" +
                "Finding peers\n" +
                "No peers found yet\n" +
                "0 B of 1.2 GB",
            DownloadsNotificationText.expanded(listOf(film, episode)),
        )
    }

    @Test
    fun `a block with only a title is a line of its own`() {
        assertEquals(
            "A Film\nDownloading 32%\n\nAnd 3 more titles",
            DownloadsNotificationText.expanded(
                listOf(
                    DownloadBlock("A Film", listOf("Downloading 32%")),
                    DownloadBlock("And 3 more titles", emptyList()),
                ),
            ),
        )
    }

    @Test
    fun `nothing to say expands to nothing`() {
        assertNull(DownloadsNotificationText.expanded(emptyList()))
        assertNull(DownloadsNotificationText.expanded(listOf(DownloadBlock("A Film", emptyList()))))
    }

    @Test
    fun `the flat lists of an intent come back as blocks`() {
        assertEquals(
            listOf(film, episode),
            DownloadsNotificationText.blocks(
                listOf(film.name, episode.name),
                listOf(3, 3),
                film.lines + episode.lines,
            ),
        )
    }

    @Test
    fun `lists that do not add up give what they can`() {
        assertEquals(
            listOf(
                DownloadBlock("A Film", listOf("one", "two")),
                DownloadBlock("A Show", emptyList()),
            ),
            DownloadsNotificationText.blocks(
                listOf("A Film", "A Show"),
                listOf(5),
                listOf("one", "two"),
            ),
        )
    }
}
