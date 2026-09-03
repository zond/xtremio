package com.zond.xtremio

/**
 * The three numbers `Notification.Builder.setProgress` wants, from the one
 * percentage the Dart side sends.
 *
 * Dart sends `-1` when it cannot say how far along the downloads are — a
 * magnet whose metadata has not resolved knows no length, and a percentage
 * of the entries that *do* know theirs would be a percentage of the wrong
 * number. That is the bar with no end. Anything else is clamped rather than
 * trusted: a bar is not the place to find out that a byte count went past
 * its total.
 */
data class DownloadsProgressBar(
    val max: Int,
    val current: Int,
    val indeterminate: Boolean,
) {
    companion object {
        const val MAX = 100

        fun of(percent: Int): DownloadsProgressBar =
            if (percent < 0) {
                DownloadsProgressBar(MAX, 0, indeterminate = true)
            } else {
                DownloadsProgressBar(MAX, percent.coerceIn(0, MAX), indeterminate = false)
            }
    }
}
