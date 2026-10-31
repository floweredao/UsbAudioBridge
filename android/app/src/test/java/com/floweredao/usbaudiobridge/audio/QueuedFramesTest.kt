package com.floweredao.usbaudiobridge.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class QueuedFramesTest {
    private val wrap = 1L shl 32

    @Test
    fun countsFramesNotYetPlayed() {
        assertEquals(480L, queuedFrames(written = 48_480, playbackHead = 48_000))
    }

    @Test
    fun neverNegative() {
        assertEquals(0L, queuedFrames(written = 100, playbackHead = 200))
    }

    @Test
    fun survivesHeadWrapAfter2Pow32Frames() {
        // Just before the wrap the head reads as a negative Int.
        assertEquals(480L, queuedFrames(written = wrap - 480, playbackHead = -960))
        // The head has wrapped back to 0 while written keeps growing.
        assertEquals(480L, queuedFrames(written = wrap + 480, playbackHead = 0))
        assertEquals(480L, queuedFrames(written = 3 * wrap + 960, playbackHead = 480))
    }
}
