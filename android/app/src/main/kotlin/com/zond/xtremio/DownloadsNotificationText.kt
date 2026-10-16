package com.zond.xtremio

/**
 * One download in the expanded notification: its title and what it is doing,
 * one fact per line, in the words Dart chose (`DownloadDetail.lines`). The
 * phrases are all Dart's, shared with the player's buffering card and the
 * Downloads rows. This side only lays them out.
 */
data class DownloadBlock(val name: String, val lines: List<String>)

/**
 * What the downloads notification says when it is pulled open, from the
 * blocks Dart sent. The one piece of that a JVM test can reach.
 */
object DownloadsNotificationText {
    /**
     * The expanded text, or null when there is nothing to expand to. One
     * download is its lines alone, since the title already names it. Several
     * are a block each, headed by the title and set apart by a blank line.
     */
    fun expanded(blocks: List<DownloadBlock>): String? {
        val shown = blocks.filter { it.name.isNotBlank() || it.lines.isNotEmpty() }
        if (shown.isEmpty()) return null
        if (shown.size == 1) {
            return shown[0].lines.joinToString("\n").ifEmpty { null }
        }
        return shown.joinToString("\n\n") { block ->
            (listOf(block.name) + block.lines).filter { it.isNotBlank() }.joinToString("\n")
        }
    }

    /**
     * The blocks back from the three flat lists an intent carries them in:
     * the titles, how many lines each has, and every line in order. Lists
     * that do not add up give what they can rather than throwing: a
     * notification is not the place to find out.
     */
    fun blocks(names: List<String>, lineCounts: List<Int>, lines: List<String>): List<DownloadBlock> {
        val blocks = mutableListOf<DownloadBlock>()
        var next = 0
        for ((index, name) in names.withIndex()) {
            val count = lineCounts.getOrElse(index) { 0 }.coerceAtLeast(0)
            val end = (next + count).coerceAtMost(lines.size)
            blocks += DownloadBlock(name, lines.subList(next, end).toList())
            next = end
        }
        return blocks
    }
}
