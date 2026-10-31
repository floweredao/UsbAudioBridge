package com.floweredao.usbaudiobridge.audio

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * Wire format shared with the Mac helper (mac/Sources/UsbAudioBridge/Protocol.swift).
 * Every message is [type: u8][length: u32 big-endian][payload].
 * The Mac listens on both ports; `adb reverse` makes them reachable as 127.0.0.1 on the tablet.
 */
object Protocol {
    const val MIC_PORT = 47123      // tablet mic -> Mac, s16le mono 48 kHz
    const val SPEAKER_PORT = 47124  // Mac -> tablet speaker, s16le stereo 48 kHz
    const val SAMPLE_RATE = 48000

    const val TYPE_AUDIO = 1
    const val TYPE_PING = 2   // payload: 8-byte sender clock; the peer echoes it back as PONG
    const val TYPE_PONG = 3
    const val TYPE_HELLO = 4  // first frame sent by the Mac on every accepted connection
    const val TYPE_JOIN = 5   // tablet -> Mac after HELLO: [session u32][lane u8][lane count u8]

    /**
     * Audio sockets per stream. adb keeps one unacknowledged packet per socket, so one socket delivers
     * audio in bunches of one USB round trip (20-40 ms on this tablet); several sockets keep several
     * packets in flight. Lane 0 carries only PING/PONG, AUDIO goes round-robin over lanes 1..AUDIO_LANES.
     */
    const val AUDIO_LANES = 4

    private const val MAX_PAYLOAD = 1 shl 16

    fun connect(port: Int): Socket {
        val socket = Socket()
        socket.tcpNoDelay = true
        socket.connect(InetSocketAddress("127.0.0.1", port), 1500)
        // The Mac pings every second, so a silent socket for 3 s means the link is gone.
        socket.soTimeout = 3000
        return socket
    }

    /** Opens the control lane plus [AUDIO_LANES] audio lanes to [port] as one session. */
    fun openLanes(port: Int): List<Lane> {
        val session = kotlin.random.Random.nextInt()
        val count = 1 + AUDIO_LANES
        val lanes = mutableListOf<Lane>()
        try {
            for (i in 0 until count) {
                val lane = Lane(connect(port))
                lanes += lane
                readHello(lane.reader)
                val join = ByteBuffer.allocate(6).putInt(session).put(i.toByte()).put(count.toByte()).array()
                lane.writer.write(TYPE_JOIN, join)
            }
        } catch (e: Exception) {
            lanes.forEach { it.close() }
            throw e
        }
        return lanes
    }

    fun longBytes(value: Long): ByteArray = ByteBuffer.allocate(8).putLong(value).array()
    fun bytesLong(bytes: ByteArray): Long = ByteBuffer.wrap(bytes, 0, 8).long

    /** RMS level of little-endian s16 samples in dBFS, floored at -90. */
    fun levelDb(bytes: ByteArray, length: Int): Float {
        var sum = 0.0
        var count = 0
        var i = 0
        while (i + 1 < length) {
            val s = ((bytes[i + 1].toInt() shl 8) or (bytes[i].toInt() and 0xff)).toShort().toDouble()
            sum += s * s
            count++
            i += 2
        }
        if (count == 0) return -90f
        val rms = sqrt(sum / count) / 32768.0
        return if (rms <= 0.0000316) -90f else (20 * log10(rms)).toFloat()
    }

    fun readHello(reader: FrameReader) {
        reader.next()
        if (reader.type != TYPE_HELLO) throw IOException("expected HELLO, got ${reader.type}")
    }

    internal fun checkLength(length: Int) {
        if (length < 0 || length > MAX_PAYLOAD) throw IOException("bad frame length $length")
    }

    /**
     * The Mac sends the speaker only whole stereo frames, PING and PONG. Over the accessory a restart on the Mac side
     * can leave the stream mid-frame, and PCM read as a header then shows up as an unknown type or a partial frame.
     */
    internal fun checkSpeakerFrame(type: Int, length: Int, accessory: Boolean) {
        if (type == TYPE_AUDIO && length % 4 != 0) throw IOException("AUDIO of $length bytes is not whole stereo frames")
        // Over adb every lane starts fresh with HELLO, so unknown types stay allowed there for newer Macs.
        if (accessory && type !in TYPE_AUDIO..TYPE_JOIN) throw IOException("frame type $type: accessory stream out of sync")
    }
}

class Lane(val socket: Socket) {
    val reader = FrameReader(socket.getInputStream())
    val writer = FrameWriter(socket.getOutputStream())

    fun close() {
        runCatching { socket.close() }
    }
}

class FrameWriter(stream: OutputStream) {
    private val out = DataOutputStream(BufferedOutputStream(stream, 16384))

    @Synchronized
    fun write(type: Int, payload: ByteArray, length: Int = payload.size) {
        out.writeByte(type)
        out.writeInt(length)
        out.write(payload, 0, length)
        out.flush()
    }

    fun ping() = write(Protocol.TYPE_PING, Protocol.longBytes(System.nanoTime()))
}

/** BufferedInputStream that can tell how many bytes it holds without asking the underlying stream. */
private class CountingBufferedInputStream(stream: InputStream, size: Int) : BufferedInputStream(stream, size) {
    @Synchronized fun buffered(): Int = count - pos
}

class FrameReader(stream: InputStream) {
    private val buffered = CountingBufferedInputStream(stream, 65536)
    private val input = DataInputStream(buffered)
    var type = 0
        private set
    var length = 0
        private set
    var buffer = ByteArray(8192)
        private set

    fun next() {
        type = input.readUnsignedByte()
        val len = input.readInt()
        Protocol.checkLength(len)
        if (buffer.size < len) buffer = ByteArray(len)
        input.readFully(buffer, 0, len)
        length = len
    }

    /** Bytes already received but not yet consumed: the network side of the playback backlog. */
    fun backlog(): Int = try {
        input.available()
    } catch (_: IOException) {
        // Accessory file descriptors do not support FIONREAD; the bytes already pulled into our buffer are
        // still the backlog, and without them the playback trim never sees delay that builds up over USB.
        buffered.buffered()
    }
}

/** Handles PING/PONG on any socket; returns true when the frame was a control frame. */
fun handleControl(reader: FrameReader, writer: FrameWriter): Boolean = when (reader.type) {
    Protocol.TYPE_PING -> {
        writer.write(Protocol.TYPE_PONG, reader.buffer.copyOf(reader.length))
        true
    }
    Protocol.TYPE_PONG -> {
        if (reader.length >= 8) {
            val rttMs = (System.nanoTime() - Protocol.bytesLong(reader.buffer)) / 1_000_000f
            BridgeState.reportRtt(rttMs)
        }
        true
    }
    else -> false
}
