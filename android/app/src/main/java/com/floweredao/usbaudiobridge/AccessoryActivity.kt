package com.floweredao.usbaudiobridge

import android.app.Activity
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Bundle
import androidx.core.content.IntentCompat
import com.floweredao.usbaudiobridge.audio.AoaLink

/**
 * Receives USB_ACCESSORY_ATTACHED when the Mac switches the tablet to AOA. Android needs an activity for the
 * accessory's "always open with" default (and grants the permission when it starts it), but this one has no
 * window and no screen-on flag: it hands the accessory to the running bridge and finishes, so the tablet stays
 * asleep and whatever app is in front stays there.
 */
class AccessoryActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // IntentCompat avoids the typed overload's Android 13 bug, which would crash the accessory hand-off.
        val accessory = intent?.let { IntentCompat.getParcelableExtra(it, UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java) }
        if (accessory != null) AoaLink.open(applicationContext, accessory)
        finish()
    }
}
