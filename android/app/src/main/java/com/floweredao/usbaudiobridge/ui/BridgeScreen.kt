package com.floweredao.usbaudiobridge.ui

import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.provider.Settings
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.BatteryAlert
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material.icons.rounded.Usb
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.floweredao.usbaudiobridge.R
import com.floweredao.usbaudiobridge.audio.BridgeState
import com.floweredao.usbaudiobridge.audio.LinkState
import com.floweredao.usbaudiobridge.audio.Status
import kotlin.math.roundToInt

@Composable
fun BridgeScreen(
    batteryUnrestricted: Boolean,
    onAllowBackground: () -> Unit,
    onStart: () -> Unit,
    onStop: () -> Unit,
) {
    val status by BridgeState.status.collectAsStateWithLifecycle()
    val settings by BridgeState.settings.collectAsStateWithLifecycle()
    val usbPlugged = rememberUsbPlugged()

    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        BoxWithConstraints(Modifier.safeDrawingPadding()) {
            val wide = maxWidth >= 720.dp
            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = if (wide) 40.dp else 20.dp, vertical = 24.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                Header(status, onStart, onStop)
                InfoStrip(status, usbPlugged)
                AnimatedVisibility(!batteryUnrestricted) { BatteryBanner(onAllowBackground) }

                val mic: @Composable (Modifier) -> Unit = { m ->
                    ChannelCard(
                        modifier = m,
                        icon = Icons.Rounded.Mic,
                        title = stringResource(R.string.mic_title),
                        caption = stringResource(R.string.mic_caption),
                        enabled = settings.micEnabled,
                        onEnabled = { v -> BridgeState.updateSettings { it.copy(micEnabled = v) } },
                        link = if (status.serviceRunning) status.mic else LinkState.Off,
                        levelDb = status.micLevelDb,
                        sliderLabel = stringResource(R.string.mic_gain),
                        sliderValue = settings.micGain,
                        sliderRange = 0f..2f,
                        onSlider = { v -> BridgeState.updateSettings { it.copy(micGain = v) } },
                    ) {
                        ToggleRow(
                            title = stringResource(R.string.echo_cancel),
                            caption = stringResource(R.string.echo_cancel_caption),
                            checked = settings.echoCancel,
                            onChecked = { v -> BridgeState.updateSettings { it.copy(echoCancel = v) } },
                        )
                        if (status.micPermission && status.micBlocked && status.mic != LinkState.Connected) {
                            SelectionContainer {
                                Text(stringResource(R.string.mic_blocked), color = MaterialTheme.colorScheme.error,
                                    style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                        if (!status.micPermission) {
                            SelectionContainer {
                                Text(stringResource(R.string.mic_permission), color = MaterialTheme.colorScheme.error,
                                    style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                    }
                }
                val speaker: @Composable (Modifier) -> Unit = { m ->
                    ChannelCard(
                        modifier = m,
                        icon = Icons.AutoMirrored.Rounded.VolumeUp,
                        title = stringResource(R.string.speaker_title),
                        caption = stringResource(R.string.speaker_caption),
                        enabled = settings.speakerEnabled,
                        onEnabled = { v -> BridgeState.updateSettings { it.copy(speakerEnabled = v) } },
                        link = if (status.serviceRunning) status.speaker else LinkState.Off,
                        levelDb = status.speakerLevelDb,
                        sliderLabel = stringResource(R.string.speaker_volume),
                        sliderValue = settings.speakerVolume,
                        sliderRange = 0f..1f,
                        onSlider = { v -> BridgeState.updateSettings { it.copy(speakerVolume = v) } },
                    ) {
                        Text(stringResource(R.string.speaker_hint), style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (wide) {
                    Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                        mic(Modifier.weight(1f))
                        speaker(Modifier.weight(1f))
                    }
                } else {
                    mic(Modifier.fillMaxWidth())
                    speaker(Modifier.fillMaxWidth())
                }
                Text(
                    stringResource(R.string.footer_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun rememberUsbPlugged(): Boolean {
    val context = LocalContext.current
    var plugged by remember { mutableStateOf(false) }
    DisposableEffect(context) {
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(c: android.content.Context?, intent: Intent?) {
                plugged = intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) == BatteryManager.BATTERY_PLUGGED_USB
            }
        }
        val sticky = context.registerReceiver(receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        plugged = sticky?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) == BatteryManager.BATTERY_PLUGGED_USB
        onDispose { context.unregisterReceiver(receiver) }
    }
    return plugged
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Header(status: Status, onStart: () -> Unit, onStop: () -> Unit) {
    val controls: @Composable () -> Unit = {
        StatusPill(status)
        FilledTonalButton(onClick = if (status.serviceRunning) onStop else onStart) {
            Icon(Icons.Rounded.PowerSettingsNew, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(if (status.serviceRunning) R.string.action_stop else R.string.action_start))
        }
    }
    // With large text the name, pill and button no longer fit on one line: put the controls on their own row.
    if (LocalDensity.current.fontScale >= 1.3f) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) { HeaderTitle() }
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) { controls() }
        }
    } else {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            HeaderTitle()
            controls()
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.HeaderTitle() {
    Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .size(52.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(Brush.linearGradient(listOf(Color(0xFF6366F1), Color(0xFF8B5CF6), Color(0xFF14B8A6)))),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.GraphicEq, contentDescription = null, tint = Color.White, modifier = Modifier.size(30.dp))
        }
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineSmall)
            Text(stringResource(R.string.tagline), style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun StatusPill(status: Status) {
    val connected = status.serviceRunning && (status.mic == LinkState.Connected || status.speaker == LinkState.Connected)
    val waiting = status.serviceRunning && !connected
    val (label, color) = when {
        connected -> stringResource(R.string.status_connected) to MaterialTheme.colorScheme.secondary
        waiting -> stringResource(R.string.status_waiting) to MaterialTheme.colorScheme.tertiary
        else -> stringResource(R.string.status_stopped) to MaterialTheme.colorScheme.outline
    }
    val dotColor by animateColorAsState(color, label = "dot")
    // Animations turned off in system settings (animator duration scale 0) means no repeating pulse.
    val context = LocalContext.current
    val reduceMotion = remember(context) {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    val pulse = rememberInfiniteTransition(label = "pulse")
    val alpha by pulse.animateFloat(
        initialValue = 1f, targetValue = if (waiting && !reduceMotion) 0.3f else 1f,
        animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "alpha",
    )
    Surface(shape = CircleShape, color = dotColor.copy(alpha = 0.14f)) {
        Row(Modifier.padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(10.dp).clip(CircleShape).background(dotColor.copy(alpha = alpha)))
            Spacer(Modifier.width(8.dp))
            Text(label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun InfoStrip(status: Status, usbPlugged: Boolean) {
    val dash = "—"
    FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        InfoChip(Icons.Rounded.Usb, stringResource(R.string.info_cable),
            stringResource(if (usbPlugged) R.string.cable_plugged else R.string.cable_unplugged))
        InfoChip(Icons.Rounded.Speed, stringResource(R.string.info_rtt),
            status.rttMs?.let { "%.1f ms".format(it) } ?: dash)
        InfoChip(Icons.Rounded.Timer, stringResource(R.string.info_latency),
            status.playbackBufferMs?.let { "%d ms".format((it + (status.rttMs ?: 0f) / 2).roundToInt()) } ?: dash)
        InfoChip(Icons.Rounded.GraphicEq, stringResource(R.string.info_format), "48 kHz · 16-bit")
    }
}

@Composable
private fun InfoChip(icon: ImageVector, label: String, value: String) {
    Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
        Row(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
            Column {
                Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(value, style = MaterialTheme.typography.titleSmall.copy(fontFamily = FontFamily.Monospace))
            }
        }
    }
}

@Composable
private fun BatteryBanner(onAllow: () -> Unit) {
    Surface(shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.tertiaryContainer) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.BatteryAlert, contentDescription = null, tint = MaterialTheme.colorScheme.onTertiaryContainer)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.battery_title), style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onTertiaryContainer)
                Text(stringResource(R.string.battery_body), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onTertiaryContainer)
            }
            TextButton(onClick = onAllow) { Text(stringResource(R.string.battery_action)) }
        }
    }
}

@Composable
private fun ChannelCard(
    modifier: Modifier,
    icon: ImageVector,
    title: String,
    caption: String,
    enabled: Boolean,
    onEnabled: (Boolean) -> Unit,
    link: LinkState,
    levelDb: Float,
    sliderLabel: String,
    sliderValue: Float,
    sliderRange: ClosedFloatingPointRange<Float>,
    onSlider: (Float) -> Unit,
    extra: @Composable () -> Unit,
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            // The whole row is the switch, so TalkBack reads the channel name together with its on/off state.
            Row(
                Modifier.toggleable(value = enabled, role = Role.Switch, onValueChange = onEnabled),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val tint = if (enabled) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh
                Box(Modifier.size(48.dp).clip(CircleShape).background(tint), contentAlignment = Alignment.Center) {
                    Icon(icon, contentDescription = null,
                        tint = if (enabled) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(title, style = MaterialTheme.typography.titleLarge)
                    Text("$caption · ${linkLabel(link)}", style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Switch(checked = enabled, onCheckedChange = null)
            }
            LevelMeter(if (link == LinkState.Connected) levelDb else -90f)
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(sliderLabel, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                    Text("${(sliderValue * 100).roundToInt()}%", style = MaterialTheme.typography.labelLarge.copy(fontFamily = FontFamily.Monospace),
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Slider(
                    modifier = Modifier.semantics { contentDescription = sliderLabel },
                    value = sliderValue,
                    onValueChange = onSlider,
                    valueRange = sliderRange,
                    colors = SliderDefaults.colors(
                        inactiveTrackColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                        activeTickColor = Color.Transparent,
                        inactiveTickColor = Color.Transparent,
                    ),
                )
            }
            extra()
        }
    }
}

@Composable
private fun linkLabel(link: LinkState) = stringResource(
    when (link) {
        LinkState.Connected -> R.string.state_on
        LinkState.Waiting -> R.string.state_waiting
        LinkState.Off -> R.string.state_off
    },
)

@Composable
private fun LevelMeter(levelDb: Float) {
    val target = ((levelDb + 60f) / 60f).coerceIn(0f, 1f)
    val fraction by animateFloatAsState(target, animationSpec = tween(90), label = "level")
    val track = MaterialTheme.colorScheme.surfaceContainerHigh
    val dbText = if (levelDb <= -89f) "-∞ dB" else "%.0f dB".format(levelDb)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Canvas(
            Modifier
                .weight(1f)
                .height(16.dp)
                .semantics { contentDescription = dbText },
        ) {
            val radius = CornerRadius(size.height / 2, size.height / 2)
            drawRoundRect(track, cornerRadius = radius)
            if (fraction > 0f) {
                drawRoundRect(
                    brush = Brush.horizontalGradient(
                        0f to MeterColors.Low, 0.65f to MeterColors.Low, 0.85f to MeterColors.Mid, 1f to MeterColors.High,
                        startX = 0f, endX = size.width,
                    ),
                    topLeft = Offset.Zero,
                    size = Size(maxOf(size.height, size.width * fraction), size.height),
                    cornerRadius = radius,
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Text(dbText, style = MaterialTheme.typography.labelLarge.copy(fontFamily = FontFamily.Monospace),
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.widthIn(min = 64.dp))
    }
}

@Composable
private fun ToggleRow(title: String, caption: String, checked: Boolean, onChecked: (Boolean) -> Unit) {
    Row(
        Modifier.toggleable(value = checked, role = Role.Switch, onValueChange = onChecked),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(caption, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = null)
    }
}
