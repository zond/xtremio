package com.zond.xtremio

import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.net.Uri
import androidx.tvprovider.media.tv.TvContractCompat
import androidx.tvprovider.media.tv.WatchNextProgram
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The `xtremio/watch_next` channel: a developer probe of the Google TV home
 * screen's "Continue watching" row (lib/features/dev/home_screen_probe.dart,
 * docs/ANDROID.md, "Home-screen probe").
 *
 * The question is whether Google TV shows Watch Next entries from an app
 * it did not install from the Play Store. Only a row this app inserts
 * answers it -- one inserted from `adb shell` belongs to
 * `com.android.shell` -- so this inserts one fixed entry and takes it out
 * again, and is not the feature.
 *
 * From Dart: `insertProbe` and `removeProbe`. Each answers a sentence for
 * the snackbar, never an error: a device with no TV provider (a phone) says
 * so, and a refusal says what it was.
 */
class WatchNextChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        channel.setMethodCallHandler(this)
    }

    fun detach() = channel.setMethodCallHandler(null)

    // One row each way, on a developer's press: done here rather than on a
    // thread of its own.
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "insertProbe" -> result.success(if (hasProvider()) insert() else HomeScreenProbe.NO_PROVIDER)
            "removeProbe" -> result.success(if (hasProvider()) remove() else HomeScreenProbe.NO_PROVIDER)
            else -> result.notImplemented()
        }
    }

    /** Whether this device has the TV provider at all; a phone has not. */
    private fun hasProvider(): Boolean =
        activity.contentResolver.acquireContentProviderClient(TvContractCompat.AUTHORITY)
            ?.also { it.close() } != null

    private fun insert(): String = try {
        // Explicit, to this app's own activity: nothing another app could
        // answer, and nothing it says about a title.
        val open = Intent(activity, MainActivity::class.java).toUri(Intent.URI_INTENT_SCHEME)
        val program = WatchNextProgram.Builder()
            .setType(TvContractCompat.WatchNextPrograms.TYPE_MOVIE)
            .setWatchNextType(TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE)
            .setTitle(HomeScreenProbe.TITLE)
            .setPosterArtUri(Uri.parse(HomeScreenProbe.POSTER))
            .setPosterArtAspectRatio(TvContractCompat.WatchNextPrograms.ASPECT_RATIO_2_3)
            .setLastEngagementTimeUtcMillis(System.currentTimeMillis())
            .setLastPlaybackPositionMillis(HomeScreenProbe.POSITION_MILLIS)
            .setDurationMillis(HomeScreenProbe.DURATION_MILLIS)
            .setInternalProviderId(HomeScreenProbe.PROVIDER_ID)
            .setIntentUri(Uri.parse(open))
            .build()
        val row = activity.contentResolver.insert(
            TvContractCompat.WatchNextPrograms.CONTENT_URI,
            program.toContentValues(),
        )
        if (row == null) HomeScreenProbe.NOT_INSERTED else HomeScreenProbe.inserted(ContentUris.parseId(row))
    } catch (error: Exception) {
        HomeScreenProbe.failed("insert", error)
    }

    /**
     * Every row of ours the probe put there. The provider shows a third-party
     * app only its own rows, and they are filtered here rather than by a
     * selection, which the provider may refuse a caller without
     * `ACCESS_ALL_EPG_DATA`.
     */
    private fun remove(): String = try {
        val rows = mutableListOf<Pair<Long, String?>>()
        activity.contentResolver.query(
            TvContractCompat.WatchNextPrograms.CONTENT_URI,
            arrayOf(
                TvContractCompat.WatchNextPrograms._ID,
                TvContractCompat.WatchNextPrograms.COLUMN_INTERNAL_PROVIDER_ID,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                rows += cursor.getLong(0) to (if (cursor.isNull(1)) null else cursor.getString(1))
            }
        }
        val removed = HomeScreenProbe.probeRows(rows).sumOf { id ->
            activity.contentResolver.delete(
                TvContractCompat.buildWatchNextProgramUri(id),
                null,
                null,
            )
        }
        HomeScreenProbe.removed(removed)
    } catch (error: Exception) {
        HomeScreenProbe.failed("remove", error)
    }

    private companion object {
        const val CHANNEL = "xtremio/watch_next"
    }
}

/**
 * The fixed entry the probe inserts and the sentences it answers: the part
 * of [WatchNextChannel] with no Android in it. The entry's `ContentValues`
 * come from `WatchNextProgram.Builder`, which needs Android to run.
 */
object HomeScreenProbe {
    const val TITLE = "Xtremio probe"

    /** The Shawshank Redemption's poster, 2:3, from Stremio's own image host. */
    const val POSTER = "https://images.metahub.space/poster/medium/tt0111161/img"

    /** What marks a row as the probe's, so remove takes only those. */
    const val PROVIDER_ID = "xtremio-probe"

    /** Ten minutes into a film of 2 h 22 min 33 s. */
    const val POSITION_MILLIS = 600_000
    const val DURATION_MILLIS = 8_553_000

    const val NO_PROVIDER =
        "This device has no TV provider, so there is no home screen to probe."

    const val NOT_INSERTED = "The TV provider took the probe and returned no row."

    fun inserted(rowId: Long) = "Inserted the probe as Watch Next row $rowId."

    fun removed(count: Int) = when (count) {
        0 -> "There was no probe to remove."
        1 -> "Removed the probe."
        else -> "Removed $count probe rows."
    }

    /** The exception's type and message: neither names anything of the viewer's. */
    fun failed(action: String, error: Throwable) =
        "Could not $action the probe: ${error.javaClass.simpleName}" +
            (error.message?.let { ": $it" } ?: "")

    /** The ids of the rows the probe put there, among this app's own. */
    fun probeRows(rows: List<Pair<Long, String?>>): List<Long> =
        rows.filter { (_, provider) -> provider == PROVIDER_ID }.map { (id, _) -> id }
}
