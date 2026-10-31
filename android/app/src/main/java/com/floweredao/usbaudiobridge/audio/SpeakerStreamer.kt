package com.floweredao.usbaudiobridge.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.IOException
import kotlin.concurrent.thread

/** Receives s16 stereo frames from the Mac and plays them with a small, bounded buffer. */
class SpeakerStreamer(private val context: Context) : Thread("uab-speaker") {
    @Volatile private var running = true
    @Volatile private var lanes: List<Lane> = emptyList()

    fun shutdown() {
        running = false
        lanes.forEach { it.close() }
        interrupt()
    }

    override fun run() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        while (running) {
            AoaLink.open(context)
            // Over AOA this thread is the only reader, so it keeps reading even with the speaker off.
            if (!BridgeState.settings.value.speakerEnabled && AoaLink.current == null) {
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
                lanes.forEach { it.close() }
                lanes = emptyList()
            }
            if (running) {
                BridgeState.updateStatus { it.copy(speakerLevelDb = -90f, playbackBufferMs = null) }
                pause(1000)
            }
        }
        setLink(LinkState.Off)
    }

    private fun session() {
        val aoa = AoaLink.current
        val opened = if (aoa != null) emptyList() else Protocol.openLanes(Protocol.SPEAKER_PORT)
        lanes = opened
        val pingWriter = aoa?.writer ?: opened[0].writer
        val audioLanes = aoa?.let { listOf(it.reader to it.writer) } ?: opened.drop(1).map { it.reader to it.writer }
        val control = if (aoa != null) null else thread(name = "uab-speaker-ctl", isDaemon = true) {
            val controlLane = opened[0]
            try {
                while (true) {
                    controlLane.reader.next()
                    handleControl(controlLane.reader, controlLane.writer)
                }
            } catch (_: Exception) {
                opened.forEach { it.close() }
            }
        }

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
            .setBufferSizeInBytes(maxOf(minBuf, BYTES_PER_MS * 80))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
        try {
            track.play()
            setLink(LinkState.Connected)
            // Start with a small device buffer and grow it only when the track actually underruns.
            var targetMs = START_BUFFER_MS
            track.bufferSizeInFrames = minOf(track.bufferCapacityInFrames, targetMs * FRAMES_PER_MS)
            var underruns = track.underrunCount
            val startedAt = SystemClock.elapsedRealtime()
            var lastAdjust = startedAt
            var windowStart = startedAt
            var windowMinMs = Float.MAX_VALUE
            var skipMs = 0f
            var lastArrival = 0L
            var maxGapMs = 0L
            Log.i(TAG, "speaker connected over ${if (aoa != null) "accessory" else "adb"} (capacity ${track.bufferCapacityInFrames} frames, using ${track.bufferSizeInFrames})")
            var written = 0L
            var volume = -1f
            var lastPing = 0L
            var lastUi = 0L
            var lastLog = 0L
            var peakDb = -90f
            var dropped = 0
            var lane = 0
            while (running) {
                val settings = BridgeState.settings.value
                if (aoa == null && (!settings.speakerEnabled || AoaLink.current != null)) break
                if (aoa?.closed == true) break
                if (settings.speakerVolume != volume) {
                    volume = settings.speakerVolume
                    track.setVolume(volume)
                }
                // The Mac sends AUDIO round-robin over the audio lanes; reading in the same rotation keeps order.
                val (reader, writer) = audioLanes[lane]
                try {
                    reader.next()
                } catch (e: IOException) {
                    aoa?.close()
                    throw e
                }
                if (handleControl(reader, writer) || reader.type != Protocol.TYPE_AUDIO) continue
                if (!settings.speakerEnabled) continue
                lane = (lane + 1) % audioLanes.size
                val arrival = SystemClock.elapsedRealtime()
                if (lastArrival != 0L) maxGapMs = maxOf(maxGapMs, arrival - lastArrival)
                lastArrival = arrival

                val queuedMs = queuedFrames(written, track.playbackHeadPosition) * 1000f / Protocol.SAMPLE_RATE
                val backlogMs = audioLanes.sumOf { it.first.backlog() }.toFloat() / BYTES_PER_MS
                val bufferMs = queuedMs + backlogMs
                if (track.underrunCount != underruns) {
                    underruns = track.underrunCount
                    // Underruns while the stream is still starting up say nothing about network jitter.
                    if (SystemClock.elapsedRealtime() - startedAt > WARMUP_MS && targetMs < MAX_TARGET_MS) {
                        targetMs += 5
                        track.bufferSizeInFrames = minOf(track.bufferCapacityInFrames, targetMs * FRAMES_PER_MS)
                    }
                    lastAdjust = SystemClock.elapsedRealtime()
                } else if (targetMs > START_BUFFER_MS && SystemClock.elapsedRealtime() - lastAdjust > SHRINK_AFTER_MS) {
                    // Adaptive in both directions: a burst of underruns (start-up, a USB hiccup) must not pin
                    // the buffer at its ceiling forever, so give back 5 ms after every quiet stretch.
                    targetMs -= 5
                    track.bufferSizeInFrames = minOf(track.bufferCapacityInFrames, targetMs * FRAMES_PER_MS)
                    lastAdjust = SystemClock.elapsedRealtime()
                }
                // Jitter-buffer trim: if the buffer never ran low during the last second, the extra is pure delay.
                windowMinMs = minOf(windowMinMs, bufferMs)
                val now0 = SystemClock.elapsedRealtime()
                if (now0 - windowStart >= 1000) {
                    if (windowMinMs > targetMs + TRIM_SLACK_MS) skipMs = windowMinMs - targetMs
                    windowStart = now0
                    windowMinMs = Float.MAX_VALUE
                }
                if (skipMs > 0f) {
                    skipMs -= reader.length / BYTES_PER_MS.toFloat()
                    dropped++
                } else if (bufferMs > targetMs + NETWORK_SLACK_MS) {
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
                    pingWriter.ping()
                    lastPing = now
                    if (aoa == null) AoaLink.open(context)
                }
                if (now - lastLog >= 1000) {
                    Log.i(TAG, "speaker level=%.1f dBFS buffer=%.0f ms target=%d ms underruns=%d dropped=%d maxGap=%d ms rtt=%s".format(
                        db, bufferMs, targetMs, underruns, dropped, maxGapMs, BridgeState.status.value.rttMs?.let { "%.1f".format(it) } ?: "-"))
                    lastLog = now
                    maxGapMs = 0
                }
            }
        } finally {
            runCatching { track.pause(); track.flush(); track.stop() }
            track.release()
            opened.forEach { it.close() }
            control?.join(500)
        }
    }

    private fun setLink(state: LinkState) = BridgeState.updateStatus { it.copy(speaker = state) }

    private fun pause(ms: Long) {
        try { sleep(ms) } catch (_: InterruptedException) { }
    }

    companion object {
        private const val TAG = "UsbAudioBridge"
        private const val BYTES_PER_MS = Protocol.SAMPLE_RATE / 1000 * 4
        private const val FRAMES_PER_MS = Protocol.SAMPLE_RATE / 1000
        private const val START_BUFFER_MS = 10
        private const val MAX_TARGET_MS = 40
        private const val NETWORK_SLACK_MS = 25
        private const val TRIM_SLACK_MS = 6
        private const val WARMUP_MS = 1500L
        private const val SHRINK_AFTER_MS = 5000L
    }
}

/**
 * Frames written to the track but not yet played. [playbackHead] is the track's frame counter, which wraps
 * every 2^32 frames (24 h 51 min at 48 kHz), so the gap is measured in 32-bit arithmetic: that wraps with it
 * as long as the real gap stays under 2^31 frames, which a bounded playback buffer guarantees.
 */
internal fun queuedFrames(written: Long, playbackHead: Int): Long =
    (written.toInt() - playbackHead).coerceAtLeast(0).toLong()
