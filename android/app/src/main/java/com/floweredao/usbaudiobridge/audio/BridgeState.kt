package com.floweredao.usbaudiobridge.audio

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

enum class LinkState { Off, Waiting, Connected }

data class Settings(
    val micEnabled: Boolean = true,
    val speakerEnabled: Boolean = true,
    val micGain: Float = 1f,
    val speakerVolume: Float = 1f,
    val echoCancel: Boolean = false,
)

data class Status(
    val serviceRunning: Boolean = false,
    val mic: LinkState = LinkState.Off,
    val speaker: LinkState = LinkState.Off,
    val micLevelDb: Float = -90f,
    val speakerLevelDb: Float = -90f,
    val rttMs: Float? = null,
    val playbackBufferMs: Float? = null,
    val micPermission: Boolean = true,
    val micBlocked: Boolean = false,
)

/** Process-wide state shared by the service threads and the UI. */
object BridgeState {
    private val _settings = MutableStateFlow(Settings())
    val settings: StateFlow<Settings> = _settings.asStateFlow()
    private val _status = MutableStateFlow(Status())
    val status: StateFlow<Status> = _status.asStateFlow()

    private var prefs: SharedPreferences? = null

    fun init(context: Context) {
        if (prefs != null) return
        val p = context.applicationContext.getSharedPreferences("bridge", Context.MODE_PRIVATE)
        prefs = p
        _settings.value = Settings(
            micEnabled = p.getBoolean("micEnabled", true),
            speakerEnabled = p.getBoolean("speakerEnabled", true),
            micGain = p.getFloat("micGain", 1f),
            speakerVolume = p.getFloat("speakerVolume", 1f),
            echoCancel = p.getBoolean("echoCancel", false),
        )
    }

    fun updateSettings(transform: (Settings) -> Settings) {
        val next = _settings.updateAndGet(transform)
        prefs?.edit()
            ?.putBoolean("micEnabled", next.micEnabled)
            ?.putBoolean("speakerEnabled", next.speakerEnabled)
            ?.putFloat("micGain", next.micGain)
            ?.putFloat("speakerVolume", next.speakerVolume)
            ?.putBoolean("echoCancel", next.echoCancel)
            ?.apply()
    }

    fun updateStatus(transform: (Status) -> Status) = _status.update(transform)

    fun reportRtt(ms: Float) = _status.update { s ->
        // Light smoothing so the number on screen does not jitter every second.
        s.copy(rttMs = s.rttMs?.let { it * 0.6f + ms * 0.4f } ?: ms)
    }
}

private fun <T> MutableStateFlow<T>.updateAndGet(transform: (T) -> T): T {
    while (true) {
        val prev = value
        val next = transform(prev)
        if (compareAndSet(prev, next)) return next
    }
}
