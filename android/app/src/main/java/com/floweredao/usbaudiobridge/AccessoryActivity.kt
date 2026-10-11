package com.floweredao.usbaudiobridge

import android.app.Activity
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
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
        val accessory = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
        }
        if (accessory != null) AoaLink.open(applicationContext, accessory)
        finish()
    }
}
