package com.floweredao.usbaudiobridge.audio

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.NoiseSuppressor
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.IOException
import java.net.Socket
import kotlin.concurrent.thread
import kotlin.math.roundToInt

/** Captures the tablet microphone and streams 10 ms s16 mono frames to the Mac. */
class MicStreamer(private val context: Context) : Thread("uab-mic") {
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
            val settings = BridgeState.settings.value
            val permitted = context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
            BridgeState.updateStatus { it.copy(micPermission = permitted) }
            if (!settings.micEnabled || !permitted) {
                setLink(LinkState.Off)
                pause(250)
                continue
            }
            setLink(LinkState.Waiting)
            // Open the mic before the socket so a blocked mic never flaps the Mac connection.
            val record = try {
                createRecord(settings.echoCancel)
            } catch (e: Exception) {
                Log.w(TAG, "mic unavailable: ${e.message}")
                BridgeState.updateStatus { it.copy(micBlocked = true) }
                pause(3000)
                continue
            }
            try {
                session(record, settings.echoCancel)
            } catch (e: Exception) {
                if (running) Log.d(TAG, "mic link: ${e.javaClass.simpleName}: ${e.message}")
            } finally {
                runCatching { socket?.close() }
                socket = null
            }
            if (running) {
                BridgeState.updateStatus { it.copy(micLevelDb = -90f) }
                pause(1000)
            }
        }
        setLink(LinkState.Off)
    }

    private fun session(record: AudioRecord, echoCancel: Boolean) {
        val sock = try {
            Protocol.connect(Protocol.MIC_PORT).also { socket = it }
        } catch (e: Exception) {
            record.release()
            throw e
        }
        val reader = FrameReader(sock.getInputStream())
        val writer = FrameWriter(sock.getOutputStream())
        try {
            Protocol.readHello(reader)
        } catch (e: Exception) {
            record.release()
            throw e
        }
        val effects = if (echoCancel) attachEffects(record.audioSessionId) else emptyList()
        val control = thread(name = "uab-mic-ctl", isDaemon = true) {
            try {
                while (true) {
                    reader.next()
                    handleControl(reader, writer)
                }
            } catch (_: Exception) {
                runCatching { sock.close() }
            }
        }
        try {
            record.startRecording()
            if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) throw IOException("mic is busy or blocked")
            BridgeState.updateStatus { it.copy(micBlocked = false) }
            setLink(LinkState.Connected)
            Log.i(TAG, "mic connected (echoCancel=$echoCancel)")
            val frame = ByteArray(FRAME_SAMPLES * 2)
            var lastPing = 0L
            var lastUi = 0L
            var lastLog = 0L
            var peakDb = -90f
            while (running) {
                val current = BridgeState.settings.value
                if (!current.micEnabled || current.echoCancel != echoCancel) break
                val n = record.read(frame, 0, frame.size)
                if (n <= 0) {
                    BridgeState.updateStatus { it.copy(micBlocked = true) }
                    throw IOException("AudioRecord.read returned $n")
                }
                applyGain(frame, n, current.micGain)
                writer.write(Protocol.TYPE_AUDIO, frame, n)

                val db = Protocol.levelDb(frame, n)
                peakDb = maxOf(peakDb, db)
                val now = SystemClock.elapsedRealtime()
                if (now - lastUi >= 50) {
                    BridgeState.updateStatus { it.copy(micLevelDb = peakDb) }
                    peakDb = -90f
                    lastUi = now
                }
                if (now - lastPing >= 1000) {
                    writer.ping()
                    lastPing = now
                }
                if (now - lastLog >= 1000) {
                    Log.i(TAG, "mic level=%.1f dBFS".format(db))
                    lastLog = now
                }
            }
        } finally {
            runCatching { record.stop() }
            record.release()
            effects.forEach { it.release() }
            runCatching { sock.close() }
            control.join(500)
        }
    }

    @SuppressLint("MissingPermission")
    private fun createRecord(echoCancel: Boolean): AudioRecord {
        val source = if (echoCancel) MediaRecorder.AudioSource.VOICE_COMMUNICATION else MediaRecorder.AudioSource.MIC
        val minBuf = AudioRecord.getMinBufferSize(Protocol.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val record = AudioRecord(
            source, Protocol.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minBuf, FRAME_SAMPLES * 2 * 4),
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw IOException("AudioRecord failed to initialize")
        }
        return record
    }

    private fun attachEffects(sessionId: Int): List<AudioEffect> {
        val list = mutableListOf<AudioEffect>()
        if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(sessionId)?.let { it.enabled = true; list += it }
        if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(sessionId)?.let { it.enabled = true; list += it }
        return list
    }

    private fun applyGain(bytes: ByteArray, length: Int, gain: Float) {
        if (gain in 0.99f..1.01f) return
        var i = 0
        while (i + 1 < length) {
            val s = ((bytes[i + 1].toInt() shl 8) or (bytes[i].toInt() and 0xff)).toShort()
            val v = (s * gain).roundToInt().coerceIn(-32768, 32767)
            bytes[i] = v.toByte()
            bytes[i + 1] = (v shr 8).toByte()
            i += 2
        }
    }

    private fun setLink(state: LinkState) = BridgeState.updateStatus { it.copy(mic = state) }

    private fun pause(ms: Long) {
        try { sleep(ms) } catch (_: InterruptedException) { }
    }

    companion object {
        private const val TAG = "UsbAudioBridge"
        const val FRAME_SAMPLES = Protocol.SAMPLE_RATE / 100 // 10 ms
    }
}
