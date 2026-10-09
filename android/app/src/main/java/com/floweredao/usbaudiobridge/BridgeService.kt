package com.floweredao.usbaudiobridge

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.floweredao.usbaudiobridge.audio.BridgeState
import com.floweredao.usbaudiobridge.audio.LinkState
import com.floweredao.usbaudiobridge.audio.MicStreamer
import com.floweredao.usbaudiobridge.audio.SpeakerStreamer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/** Foreground service that keeps the audio bridge alive while the screen is off. */
class BridgeService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var mic: MicStreamer? = null
    private var speaker: SpeakerStreamer? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        BridgeState.init(this)
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, getString(R.string.notif_channel), NotificationManager.IMPORTANCE_LOW),
            )
        }
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "UsbAudioBridge:bridge")
            .apply { setReferenceCounted(false); acquire() }
        scope.launch {
            BridgeState.status
                .map { it.mic to it.speaker }
                .distinctUntilChanged()
                .collect { (m, s) -> nm.notify(NOTIF_ID, buildNotification(m, s)) }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val status = BridgeState.status.value
        val hasMic = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && hasMic) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        } else 0
        ServiceCompat.startForeground(this, NOTIF_ID, buildNotification(status.mic, status.speaker), type)
        if (mic == null) mic = MicStreamer(applicationContext).also { it.start() }
        if (speaker == null) speaker = SpeakerStreamer().also { it.start() }
        BridgeState.updateStatus { it.copy(serviceRunning = true) }
        return START_STICKY
    }

    override fun onDestroy() {
        mic?.shutdown()
        speaker?.shutdown()
        mic = null
        speaker = null
        scope.cancel()
        wakeLock?.release()
        BridgeState.updateStatus {
            it.copy(serviceRunning = false, mic = LinkState.Off, speaker = LinkState.Off,
                micLevelDb = -90f, speakerLevelDb = -90f, rttMs = null, playbackBufferMs = null)
        }
        super.onDestroy()
    }

    private fun buildNotification(mic: LinkState, speaker: LinkState): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, BridgeService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE,
        )
        val connected = mic == LinkState.Connected || speaker == LinkState.Connected
        val text = if (connected) {
            getString(R.string.notif_connected, label(mic), label(speaker))
        } else getString(R.string.notif_waiting)
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_bridge)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(0, getString(R.string.action_stop), stop)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun label(state: LinkState) = getString(
        when (state) {
            LinkState.Connected -> R.string.state_on
            LinkState.Waiting -> R.string.state_waiting
            LinkState.Off -> R.string.state_off
        },
    )

    companion object {
        private const val CHANNEL = "bridge"
        private const val NOTIF_ID = 1
        private const val ACTION_STOP = "com.floweredao.usbaudiobridge.STOP"

        fun start(context: Context) =
            ContextCompat.startForegroundService(context, Intent(context, BridgeService::class.java))

        fun stop(context: Context) = context.stopService(Intent(context, BridgeService::class.java))
    }
}
