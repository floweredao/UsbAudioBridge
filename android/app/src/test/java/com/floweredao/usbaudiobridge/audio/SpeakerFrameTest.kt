package com.floweredao.usbaudiobridge.audio

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SpeakerFrameTest {
    private fun frame(type: Int, payload: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        FrameWriter(out).write(type, payload)
        return out.toByteArray()
    }

    /** Reads every frame the way the speaker loop does and returns the types it accepted. */
    private fun read(bytes: ByteArray, accessory: Boolean): List<Int> {
        val reader = FrameReader(ByteArrayInputStream(bytes))
        val types = mutableListOf<Int>()
        while (true) {
            try {
                reader.next()
            } catch (_: java.io.EOFException) {
                return types
            }
            Protocol.checkSpeakerFrame(reader.type, reader.length, accessory)
            types += reader.type
        }
    }

    @Test
    fun aWellFormedStreamIsAccepted() {
        val stream = frame(Protocol.TYPE_PING, ByteArray(8)) + frame(Protocol.TYPE_AUDIO, ByteArray(960))
        assertEquals(listOf(Protocol.TYPE_PING, Protocol.TYPE_AUDIO), read(stream, accessory = true))
    }

    @Test
    fun silenceReadMidFrameOverTheAccessoryIsADesync() {
        // Starting inside a silent AUDIO payload, the reader sees zero bytes: type 0, length 0, again and again.
        val stream = ByteArray(5) + frame(Protocol.TYPE_AUDIO, ByteArray(960))
        assertThrows(IOException::class.java) { read(stream, accessory = true) }
    }

    @Test
    fun aPartialStereoFrameIsRefusedOnAnyLink() {
        val stream = frame(Protocol.TYPE_AUDIO, ByteArray(6))
        assertThrows(IOException::class.java) { read(stream, accessory = false) }
        assertThrows(IOException::class.java) { read(stream, accessory = true) }
    }

    @Test
    fun unknownTypesStayAllowedOverAdb() {
        val stream = frame(9, ByteArray(3)) + frame(Protocol.TYPE_AUDIO, ByteArray(960))
        assertEquals(listOf(9, Protocol.TYPE_AUDIO), read(stream, accessory = false))
    }
}
