package com.zond.xtremio

import android.speech.SpeechRecognizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a recognizer's callbacks become on the way to Dart, which
 * `SpeechEvent.fromMap` (lib/shell/speech_input.dart) reads back by name: a
 * word changed on one side only is an error the viewer is told in the
 * wrong words. The constants are compile-time ones, so no Android is needed
 * to reach them.
 */
class SpeechEventsTest {
    @Test
    fun `every error the viewer is told apart has its own word`() {
        val words = mapOf(
            SpeechRecognizer.ERROR_NO_MATCH to "noMatch",
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT to "noMatch",
            SpeechRecognizer.ERROR_AUDIO to "audio",
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS to "permission",
            SpeechRecognizer.ERROR_NETWORK to "network",
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT to "network",
            SpeechRecognizer.ERROR_SERVER to "network",
            SpeechRecognizer.ERROR_SERVER_DISCONNECTED to "network",
            SpeechRecognizer.ERROR_TOO_MANY_REQUESTS to "network",
            SpeechRecognizer.ERROR_CLIENT to "other",
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY to "other",
            -1 to "other",
        )
        for ((code, word) in words) {
            assertEquals("code $code", word, SpeechEvents.error(code))
        }
    }

    @Test
    fun `a failure carries the word and never the code`() {
        assertEquals(
            mapOf("type" to "error", "error" to "audio"),
            SpeechEvents.failed(SpeechRecognizer.ERROR_AUDIO),
        )
    }

    @Test
    fun `transcripts cross as partial and final`() {
        assertEquals(mapOf("type" to "partial", "text" to "the"), SpeechEvents.partial("the"))
        assertEquals(mapOf("type" to "final", "text" to "the thing"), SpeechEvents.final("the thing"))
    }

    @Test
    fun `the top transcript, and nothing for none or a blank one`() {
        assertEquals("the thing", SpeechEvents.first(listOf(" the thing ", "a thing")))
        assertNull(SpeechEvents.first(listOf("  ")))
        assertNull(SpeechEvents.first(emptyList()))
        assertNull(SpeechEvents.first(null))
    }

    @Test
    fun `only a missing language sends the on-device recognizer to the network one`() {
        assertTrue(SpeechEvents.isMissingLanguage(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED))
        assertTrue(SpeechEvents.isMissingLanguage(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE))
        assertFalse(SpeechEvents.isMissingLanguage(SpeechRecognizer.ERROR_AUDIO))
        assertFalse(SpeechEvents.isMissingLanguage(SpeechRecognizer.ERROR_NO_MATCH))
    }
}
