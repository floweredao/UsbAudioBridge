package com.floweredao.usbaudiobridge

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.mutableStateOf
import com.floweredao.usbaudiobridge.audio.AoaLink
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
        // Only the user opens this screen. The Mac helper starts BridgeService directly over adb (the shell
        // uid may grant the mic to a foreground service), and accessory attaches go to AccessoryActivity,
        // so nothing here wakes the screen or comes to the front on its own.
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
        openAccessory(intent)
        startBridge()
    }

    override fun onResume() {
        super.onResume()
        batteryUnrestricted.value = getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        openAccessory(intent)
        startBridge()
    }

    private fun openAccessory(intent: Intent?) {
        val accessory = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
        }
        // The user opened the app, so this is the one place allowed to show the accessory permission prompt.
        AoaLink.open(this, accessory, ask = true)
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
