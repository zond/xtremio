package com.zond.xtremio

import android.content.pm.PackageInstaller
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The words a `PackageInstaller` status becomes on the way to Dart, which
 * `InstallResult.parse` (lib/features/update/apk_installer.dart) reads
 * back by name: a word changed on one side only is an install that fails
 * with "The install failed" whatever really happened. The constants are
 * compile-time ones, so no Android is needed to reach them.
 */
class InstallOutcomeTest {
    @Test
    fun `every status Dart tells apart has its own word`() {
        val words = mapOf(
            PackageInstaller.STATUS_SUCCESS to "success",
            PackageInstaller.STATUS_FAILURE_ABORTED to "aborted",
            PackageInstaller.STATUS_FAILURE_CONFLICT to "conflict",
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE to "incompatible",
            PackageInstaller.STATUS_FAILURE_INVALID to "invalid",
            PackageInstaller.STATUS_FAILURE_STORAGE to "storage",
            PackageInstaller.STATUS_FAILURE_BLOCKED to "blocked",
        )
        for ((status, word) in words) {
            assertEquals(word, InstallOutcome.name(status))
        }
    }

    @Test
    fun `anything else is a plain failure`() {
        assertEquals("failure", InstallOutcome.name(PackageInstaller.STATUS_FAILURE))
        assertEquals("failure", InstallOutcome.name(-1))
    }

    @Test
    fun `Android's message goes with the word`() {
        assertEquals(
            mapOf("outcome" to "conflict", "message" to "INSTALL_FAILED_UPDATE_INCOMPATIBLE"),
            InstallOutcome.of(
                PackageInstaller.STATUS_FAILURE_CONFLICT,
                "INSTALL_FAILED_UPDATE_INCOMPATIBLE",
            ),
        )
    }
}
