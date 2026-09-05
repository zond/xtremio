package com.zond.xtremio

import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * One mode a display offers, as `Display.getSupportedModes()` describes it,
 * flattened to the four numbers that choosing between them needs.
 *
 * A plain data class rather than `Display.Mode` so that the choosing has no
 * Android in it, and so the one piece of this feature with a right answer
 * can be tested on the JVM (`FrameRateModeTest`). Everything else here --
 * the surface, the window, the display -- needs a device.
 */
data class FrameRateMode(
    val id: Int,
    val width: Int,
    val height: Int,
    val refreshRate: Float,
) {
    companion object {
        /**
         * How far a mode may sit from presenting every frame for the same
         * length of time, in frames per second, and still count as a match.
         *
         * Loose enough to take a 24.000 Hz mode for a 23.976 fps film --
         * 0.024 apart, one repeated frame every forty seconds, against one
         * every other frame on a 59.94 Hz output -- and tight enough that
         * nothing else on a television's list qualifies: 59.94 Hz is 4.0
         * away from a whole multiple of 23.976, and 50 Hz is 1.02 away.
         */
        const val MAX_CADENCE_ERROR = 0.05

        /**
         * The mode to ask the display for so that [fps] frames a second are
         * presented evenly, or null when there is nothing to ask for --
         * [current] is already the best of them, or none of them divides
         * into [fps] closely enough to be worth a mode change.
         *
         * Only modes of [current]'s own size are considered: which
         * resolution the display runs at is the viewer's business and the
         * platform's, and a film is not a reason to change it.
         *
         * A mode matches when its refresh rate is a whole multiple of the
         * content's -- 23.976 fps is even on 23.976 Hz and just as even on
         * 47.952 Hz, where every frame is shown exactly twice -- and the
         * evenest of them wins, which is why the film's own rate is taken
         * over a multiple of it and over a mode that is merely near. That
         * is also what makes the reading legible: `dumpsys display` should
         * name 23.976 while a 23.976 fps film plays.
         */
        fun matching(
            fps: Double,
            current: FrameRateMode,
            modes: List<FrameRateMode>,
        ): Int? {
            if (!fps.isFinite() || fps <= 0) return null
            val best =
                modes
                    .filter { it.width == current.width && it.height == current.height }
                    .mapNotNull { mode -> cadenceError(fps, mode)?.let { mode to it } }
                    .minByOrNull { it.second }
                    ?.first ?: return null
            return if (best.id == current.id) null else best.id
        }

        /**
         * How far [mode] is from showing each of [fps] frames for the same
         * number of refreshes, or null when it cannot: a rate below the
         * content's own has no whole multiple to offer, and one past
         * [MAX_CADENCE_ERROR] is the uneven cadence this exists to avoid.
         */
        private fun cadenceError(fps: Double, mode: FrameRateMode): Double? {
            val rate = mode.refreshRate.toDouble()
            val multiple = (rate / fps).roundToInt()
            if (multiple < 1) return null
            val error = abs(rate / multiple - fps)
            return if (error <= MAX_CADENCE_ERROR) error else null
        }
    }
}
