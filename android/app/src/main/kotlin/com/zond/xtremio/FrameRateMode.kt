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
         * The band a rate has to fall in to be believed as the rate of
         * something somebody filmed.
         *
         * The rate comes from the container, which is a claim and not a
         * measurement: mpv computes `container-fps` from the track's own
         * timing, and a Matroska file whose `default_duration` is written
         * as one millisecond reports 1000 fps. Below the floor is the
         * same kind of damage the other way, and neither is worth a mode
         * change -- on Android 12 and up the ask carries
         * `CHANGE_FRAME_RATE_ALWAYS`, which is what permits the second of
         * black picture, so asserting a rate the content is not costs the
         * viewer a blank screen and leaves them on the wrong mode
         * afterwards.
         *
         * The band holds every rate real content declares. The lowest is
         * film at 23.976 and the highest is 119.88 (120 fps pulled the
         * NTSC way, which is what a 120 fps release actually reports);
         * outside it, nothing a television can present evenly is being
         * described.
         */
        const val MIN_CONTENT_RATE = 20.0
        const val MAX_CONTENT_RATE = 120.0

        /**
         * Whether [fps] is a rate worth asking the display for at all --
         * the one question both paths ask, since [matching] is only
         * reached below Android 12 and `Surface.setFrameRate` has no
         * sanity of its own.
         */
        fun plausible(fps: Double): Boolean =
            fps.isFinite() && fps >= MIN_CONTENT_RATE && fps <= MAX_CONTENT_RATE

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
            if (!plausible(fps)) return null
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
