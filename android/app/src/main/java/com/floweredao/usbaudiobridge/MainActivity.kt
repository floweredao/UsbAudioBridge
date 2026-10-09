package com.floweredao.usbaudiobridge

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.mutableStateOf
import com.floweredao.usbaudiobridge.audio.BridgeState
import com.floweredao.usbaudiobridge.ui.BridgeScreen
import com.floweredao.usbaudiobridge.ui.BridgeTheme

class MainActivity : ComponentActivity() {
    private val batteryUnrestricted = mutableStateOf(true)

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        // Restart so the foreground service picks up the microphone type once access is granted.
        BridgeService.start(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android only lets a foreground service use the mic if it was started while the app was visible,
        // so wake the screen and show above the lock screen when the Mac launches us over adb.
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
        enableEdgeToEdge()
        BridgeState.init(this)
        setContent {
            BridgeTheme {
                BridgeScreen(
                    batteryUnrestricted = batteryUnrestricted.value,
                    onAllowBackground = ::requestBatteryExemption,
                    onStart = ::startBridge,
                    onStop = { BridgeService.stop(this) },
                )
            }
        }
        startBridge()
    }

    override fun onResume() {
        super.onResume()
        batteryUnrestricted.value = getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // The Mac helper re-launches us with `am start` whenever the tablet is plugged in.
        startBridge()
    }

    private fun startBridge() {
        val missing = buildList {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        BridgeService.start(this)
        if (missing.isNotEmpty()) permissions.launch(missing.toTypedArray())
    }

    @SuppressLint("BatteryLife")
    private fun requestBatteryExemption() {
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
        runCatching { startActivity(intent) }.onFailure {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }
}
