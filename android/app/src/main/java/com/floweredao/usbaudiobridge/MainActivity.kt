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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.res.stringResource
import androidx.core.content.IntentCompat
import com.floweredao.usbaudiobridge.audio.AoaLink
import com.floweredao.usbaudiobridge.audio.BridgeState
import com.floweredao.usbaudiobridge.ui.BridgeScreen
import com.floweredao.usbaudiobridge.ui.BridgeTheme

private const val MIC_ASKED = "micAsked"

class MainActivity : ComponentActivity() {
    private val batteryUnrestricted = mutableStateOf(true)
    /** Permissions waiting for the user to read why they are asked before Android shows its prompt. */
    private val pendingPermissions = mutableStateOf<List<String>>(emptyList())

    private val prefs by lazy { getSharedPreferences("ui", MODE_PRIVATE) }

    /**
     * After the mic was refused for good, Android answers a request at once without a prompt. A first request
     * looks the same (no rationale either), so the app remembers that it has asked before.
     */
    private fun micDeniedForGood() = prefs.getBoolean(MIC_ASKED, false) &&
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED &&
        !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)

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
        // Read the real value before the first frame so the battery banner does not push the cards down later.
        batteryUnrestricted.value = isBatteryUnrestricted()
        setContent {
            BridgeTheme {
                BridgeScreen(
                    batteryUnrestricted = batteryUnrestricted.value,
                    onAllowBackground = ::requestBatteryExemption,
                    onStart = ::startBridge,
                    onStop = { BridgeService.stop(this) },
                )
                val pending = pendingPermissions.value
                if (pending.isNotEmpty()) {
                    val toSettings = Manifest.permission.RECORD_AUDIO in pending && micDeniedForGood()
                    val ask: () -> Unit = {
                        pendingPermissions.value = emptyList()
                        if (toSettings) {
                            runCatching { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))) }
                        } else {
                            prefs.edit().putBoolean(MIC_ASKED, true).apply()
                            permissions.launch(pending.toTypedArray())
                        }
                    }
                    AlertDialog(
                        onDismissRequest = ask,
                        confirmButton = { TextButton(onClick = ask) { Text(stringResource(R.string.permission_continue)) } },
                        title = { Text(stringResource(R.string.permission_title)) },
                        text = {
                            Text(buildList {
                                if (Manifest.permission.RECORD_AUDIO in pending) add(stringResource(R.string.permission_mic))
                                if (Manifest.permission.POST_NOTIFICATIONS in pending) add(stringResource(R.string.permission_notifications))
                                add(stringResource(if (toSettings) R.string.permission_next_settings else R.string.permission_next))
                            }.joinToString(" "))
                        },
                    )
                }
            }
        }
        openAccessory(intent)
        startBridge()
    }

    override fun onResume() {
        super.onResume()
        batteryUnrestricted.value = isBatteryUnrestricted()
        // Back from Settings with the mic allowed: restart the running service so it takes the microphone type.
        if (BridgeState.status.value.serviceRunning) BridgeService.start(this)
    }

    private fun isBatteryUnrestricted() =
        getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        openAccessory(intent)
        startBridge()
    }

    private fun openAccessory(intent: Intent?) {
        // IntentCompat avoids the typed overload's Android 13 bug.
        val accessory = intent?.let { IntentCompat.getParcelableExtra(it, UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java) }
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
        // Say why first; the dialog's Continue button opens Android's prompt.
        if (missing.isNotEmpty()) pendingPermissions.value = missing
    }

    @SuppressLint("BatteryLife")
    private fun requestBatteryExemption() {
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
        // Some builds have neither screen; tapping the button must not crash the app.
        runCatching { startActivity(intent) }
            .recoverCatching { startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) }
    }
}
