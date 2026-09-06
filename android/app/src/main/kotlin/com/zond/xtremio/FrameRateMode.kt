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
/**
 * What one mode would make of the content: how far it is from showing every
 * frame for the same length of time, and over how many refreshes each frame
 * would be held. The second is what settles a tie between two modes that
 * are equally even.
 */
private data class Cadence(val error: Double, val multiple: Int)

/**
 * What to ask a display for on Android 12 and up, once the box's own
 * "Match content frame rate" setting has been read
 * ([FrameRateMode.askFor]).
 */
enum class FrameRateAsk {
    /** Nothing: the viewer has turned frame rate matching off. */
    NOTHING,

    /** The surface vote alone, which this box will honour by itself. */
    SURFACE,

    /**
     * The surface vote, and then the mode named outright -- the vote alone
     * cannot make the switch this display needs.
     */
    SURFACE_THEN_MODE,
}

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
         * `DisplayManager.MATCH_CONTENT_FRAMERATE_*`, copied so that this
         * file keeps no Android in it and the choosing stays testable on
         * the JVM. The values were read off
         * `platforms/android-36/android.jar`, where AOSP spells the middle
         * one `SEAMLESSS_ONLY` -- a reason of its own not to name it in
         * [MainActivity], which hands the number over as it comes.
         */
        const val MATCH_CONTENT_UNKNOWN = -1
        const val MATCH_CONTENT_NEVER = 0
        const val MATCH_CONTENT_SEAMLESS_ONLY = 1
        const val MATCH_CONTENT_ALWAYS = 2

        /**
         * What to ask for, given what
         * `DisplayManager.getMatchContentFrameRateUserPreference()`
         * answers.
         *
         * `Surface.setFrameRate` is a *vote*, and this setting decides
         * what a vote is allowed to do. The owner's Chromecast reads
         * `settings get secure match_content_frame_rate` as null, which is
         * not "no": with the setting unset AOSP's `DisplayModeDirector`
         * runs at `SWITCHING_TYPE_WITHIN_GROUPS`, which is
         * `MATCH_CONTENT_FRAMERATE_SEAMLESS_ONLY` -- seamless switches
         * only. 59.94 Hz to 23.976 Hz retrains the HDMI link and is never
         * seamless, so the vote is dropped in silence. That is the reading
         * this exists for: `FrameRateOverrides=none`,
         * `frameRateOverrideConfig=Disabled`, and `mActiveModeId` still on
         * the 59.94 Hz mode while a 23.976 fps film played.
         *
         * Naming a mode is not gated the same way. A window's
         * `preferredDisplayModeId` becomes an app request vote for a base
         * mode, and `DisplayModeDirector` flattens those only when mode
         * switching is off altogether (`SWITCHING_TYPE_NONE`); under
         * seamless-only the mode a window asks for is the mode the display
         * takes. It is the path television video apps used before Android
         * 12, and it is the fallback here.
         *
         * So: [MATCH_CONTENT_NEVER] is `SWITCHING_TYPE_NONE`, where
         * neither path can do anything and the viewer has said as much --
         * nothing is asked for. [MATCH_CONTENT_ALWAYS] is the box that
         * honours the vote, where naming a mode as well is only a second
         * way of saying it. Anything else -- seamless-only, or a box that
         * will not say -- gets both, since the vote may still take on a
         * display where the switch happens to be seamless and the mode
         * ask is what covers the one this app was written for.
         */
        fun askFor(matchContent: Int): FrameRateAsk =
            when (matchContent) {
                MATCH_CONTENT_NEVER -> FrameRateAsk.NOTHING
                MATCH_CONTENT_ALWAYS -> FrameRateAsk.SURFACE
                else -> FrameRateAsk.SURFACE_THEN_MODE
            }

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
         * evenest of them wins, which is why a mode that is merely near
         * loses to one that divides.
         *
         * Two modes can be exactly as even, and 23.976 against 47.952 is
         * that case rather than a contrived one: both are stored as
         * `Float`, and `47.95199966430664 / 2` and `23.97599983215332` are
         * the same distance from 23.976 down to the last bit. The fewest
         * refreshes per frame breaks it, so the film's own rate wins --
         * the tie must not be settled by the order `getSupportedModes()`
         * happens to return, which is the display HAL's and not ours.
         * That is also what makes the reading legible: `dumpsys display`
         * should name 23.976 while a 23.976 fps film plays.
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
                    .mapNotNull { mode -> cadenceOf(fps, mode)?.let { mode to it } }
                    .minWithOrNull(compareBy({ it.second.error }, { it.second.multiple }))
                    ?.first ?: return null
            return if (best.id == current.id) null else best.id
        }

        /**
         * How [mode] would show [fps] frames a second, or null when it
         * cannot: a rate below the content's own has no whole multiple to
         * offer, and one past [MAX_CADENCE_ERROR] is the uneven cadence
         * this exists to avoid.
         */
        private fun cadenceOf(fps: Double, mode: FrameRateMode): Cadence? {
            val rate = mode.refreshRate.toDouble()
            val multiple = (rate / fps).roundToInt()
            if (multiple < 1) return null
            val error = abs(rate / multiple - fps)
            return if (error <= MAX_CADENCE_ERROR) Cadence(error, multiple) else null
        }
    }
}
