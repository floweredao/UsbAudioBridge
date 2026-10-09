package com.floweredao.usbaudiobridge.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.net.Socket

/** Receives s16 stereo frames from the Mac and plays them with a small, bounded buffer. */
class SpeakerStreamer : Thread("uab-speaker") {
    @Volatile private var running = true
    @Volatile private var socket: Socket? = null

    fun shutdown() {
        running = false
        runCatching { socket?.close() }
        interrupt()
    }

    override fun run() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        while (running) {
            if (!BridgeState.settings.value.speakerEnabled) {
                setLink(LinkState.Off)
                pause(250)
                continue
            }
            setLink(LinkState.Waiting)
            try {
                session()
            } catch (e: Exception) {
                if (running) Log.d(TAG, "speaker link: ${e.javaClass.simpleName}: ${e.message}")
            } finally {
                runCatching { socket?.close() }
                socket = null
            }
            if (running) {
                BridgeState.updateStatus { it.copy(speakerLevelDb = -90f, playbackBufferMs = null) }
                pause(1000)
            }
        }
        setLink(LinkState.Off)
    }

    private fun session() {
        val sock = Protocol.connect(Protocol.SPEAKER_PORT)
        socket = sock
        val reader = FrameReader(sock.getInputStream())
        val writer = FrameWriter(sock.getOutputStream())
        Protocol.readHello(reader)

        val minBuf = AudioTrack.getMinBufferSize(Protocol.SAMPLE_RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(Protocol.SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(minBuf, BYTES_PER_MS * 30))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
        try {
            track.play()
            setLink(LinkState.Connected)
            Log.i(TAG, "speaker connected (track buffer ${track.bufferSizeInFrames} frames)")
            var written = 0L
            var volume = -1f
            var lastPing = 0L
            var lastUi = 0L
            var lastLog = 0L
            var peakDb = -90f
            var dropped = 0
            while (running) {
                val settings = BridgeState.settings.value
                if (!settings.speakerEnabled) break
                if (settings.speakerVolume != volume) {
                    volume = settings.speakerVolume
                    track.setVolume(volume)
                }
                reader.next()
                if (handleControl(reader, writer) || reader.type != Protocol.TYPE_AUDIO) continue

                val played = track.playbackHeadPosition.toLong() and 0xffffffffL
                val queuedMs = (written - played).coerceAtLeast(0) * 1000f / Protocol.SAMPLE_RATE
                val backlogMs = reader.backlog().toFloat() / BYTES_PER_MS
                val bufferMs = queuedMs + backlogMs
                if (bufferMs > MAX_BUFFER_MS) {
                    // Drop to catch up: keeps latency bounded when the clocks drift or a burst arrives.
                    dropped++
                } else {
                    track.write(reader.buffer, 0, reader.length)
                    written += reader.length / 4
                }

                val db = Protocol.levelDb(reader.buffer, reader.length)
                peakDb = maxOf(peakDb, db)
                val now = SystemClock.elapsedRealtime()
                if (now - lastUi >= 50) {
                    val p = peakDb
                    BridgeState.updateStatus { it.copy(speakerLevelDb = p, playbackBufferMs = bufferMs) }
                    peakDb = -90f
                    lastUi = now
                }
                if (now - lastPing >= 1000) {
                    writer.ping()
                    lastPing = now
                }
                if (now - lastLog >= 1000) {
                    Log.i(TAG, "speaker level=%.1f dBFS buffer=%.0f ms dropped=%d rtt=%s".format(
                        db, bufferMs, dropped, BridgeState.status.value.rttMs?.let { "%.1f".format(it) } ?: "-"))
                    lastLog = now
                }
            }
        } finally {
            runCatching { track.pause(); track.flush(); track.stop() }
            track.release()
            runCatching { sock.close() }
        }
    }

    private fun setLink(state: LinkState) = BridgeState.updateStatus { it.copy(speaker = state) }

    private fun pause(ms: Long) {
        try { sleep(ms) } catch (_: InterruptedException) { }
    }

    companion object {
        private const val TAG = "UsbAudioBridge"
        private const val BYTES_PER_MS = Protocol.SAMPLE_RATE / 1000 * 4
        private const val MAX_BUFFER_MS = 70f
    }
}
