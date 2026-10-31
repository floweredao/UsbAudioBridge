package com.floweredao.usbaudiobridge.audio

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackStallTest {
    private val limit = SpeakerStreamer.STALL_LIMIT_MS

    @Test
    fun aMovingHeadNeverStalls() {
        val stall = PlaybackStall()
        var now = 0L
        var head = 0
        repeat(2000) {
            now += 5
            head += 240
            assertFalse("head is moving at $now ms", stall.stalled(head, queued = 480, nowMs = now))
        }
    }

    @Test
    fun aFrozenHeadWithAudioQueuedStallsAfterTheLimit() {
        val stall = PlaybackStall()
        assertFalse(stall.stalled(playbackHead = 48_000, queued = 480, nowMs = 0))
        assertFalse(stall.stalled(playbackHead = 48_000, queued = 480, nowMs = limit))
        assertTrue(stall.stalled(playbackHead = 48_000, queued = 480, nowMs = limit + 1))
    }

    @Test
    fun aFrozenHeadWithAnEmptyQueueIsJustAnUnderrun() {
        val stall = PlaybackStall()
        assertFalse(stall.stalled(playbackHead = 48_000, queued = 0, nowMs = 0))
        assertFalse(stall.stalled(playbackHead = 48_000, queued = 0, nowMs = 10 * limit))
    }

    @Test
    fun theHeadMovingAgainClearsTheStall() {
        val stall = PlaybackStall()
        assertFalse(stall.stalled(playbackHead = 48_000, queued = 480, nowMs = 0))
        assertFalse(stall.stalled(playbackHead = 48_240, queued = 480, nowMs = limit))
        assertFalse(stall.stalled(playbackHead = 48_240, queued = 480, nowMs = limit + limit))
        assertTrue(stall.stalled(playbackHead = 48_240, queued = 480, nowMs = 2 * limit + 1))
    }
}
