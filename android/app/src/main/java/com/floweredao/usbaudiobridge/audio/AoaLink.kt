package com.floweredao.usbaudiobridge.audio

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * USB accessory (AOA) link to the Mac: one bulk pipe per direction, no adb in between.
 * Mac -> tablet carries speaker AUDIO plus PING/PONG; tablet -> Mac carries mic AUDIO plus PING/PONG.
 * While a link is open both streamers use it; when it fails they fall back to the adb lanes.
 */
class AoaLink private constructor(private val fd: ParcelFileDescriptor) {
    val reader = FrameReader(FileInputStream(fd.fileDescriptor))
    val writer = FrameWriter(FileOutputStream(fd.fileDescriptor))
    @Volatile var closed = false
        private set

    fun close() {
        if (closed) return
        closed = true
        runCatching { fd.close() }
        if (current === this) current = null
        Log.i(TAG, "accessory link closed")
    }

    companion object {
        private const val TAG = "UsbAudioBridge"
        const val MANUFACTURER = "floweredao"
        const val MODEL = "UsbAudioBridge"

        @Volatile var current: AoaLink? = null
            private set
        private var permissionAsked = false

        @Synchronized
        fun open(context: Context, accessory: UsbAccessory? = null, ask: Boolean = false): Boolean {
            current?.let { if (!it.closed) return true }
            val usb = context.getSystemService(UsbManager::class.java) ?: return false
            val target = accessory ?: usb.accessoryList?.firstOrNull { it.manufacturer == MANUFACTURER && it.model == MODEL }
                ?: return false
            if (!usb.hasPermission(target)) {
                // Android only offers "always open" when the accessory attaches while we are installed;
                // if it was attached earlier, ask once so the same prompt (with that checkbox) appears.
                // Only when the user has the app open: a prompt from the background would pop over whatever they use.
                if (ask && !permissionAsked) {
                    permissionAsked = true
                    Log.i(TAG, "accessory attached but not permitted; asking")
                    val intent = Intent("com.floweredao.usbaudiobridge.USB_PERMISSION").setPackage(context.packageName)
                    usb.requestPermission(target, PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_MUTABLE))
                }
                return false
            }
            val fd = usb.openAccessory(target) ?: return false
            current = AoaLink(fd)
            Log.i(TAG, "accessory link open")
            return true
        }
    }
}
