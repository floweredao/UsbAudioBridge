package com.floweredao.usbaudiobridge.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight

private val Light = lightColorScheme(
    primary = Color(0xFF4F46E5), onPrimary = Color.White,
    primaryContainer = Color(0xFFE2E1FF), onPrimaryContainer = Color(0xFF17126E),
    secondary = Color(0xFF0E8F72), onSecondary = Color.White,
    secondaryContainer = Color(0xFFCDF3E5), onSecondaryContainer = Color(0xFF00382A),
    tertiary = Color(0xFFB45309), onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFFE8CC), onTertiaryContainer = Color(0xFF3D1E00),
    background = Color(0xFFF5F5FA), onBackground = Color(0xFF15151C),
    surface = Color(0xFFF5F5FA), onSurface = Color(0xFF15151C),
    surfaceContainer = Color(0xFFFFFFFF), surfaceContainerHigh = Color(0xFFEDEDF5),
    surfaceVariant = Color(0xFFE5E5EF), onSurfaceVariant = Color(0xFF585868),
    outline = Color(0xFF8A8A9A), outlineVariant = Color(0xFFDCDCE6),
)

private val Dark = darkColorScheme(
    primary = Color(0xFFBDB9FF), onPrimary = Color(0xFF221C8F),
    primaryContainer = Color(0xFF3B33AD), onPrimaryContainer = Color(0xFFE2E1FF),
    secondary = Color(0xFF63DDB8), onSecondary = Color(0xFF00382A),
    secondaryContainer = Color(0xFF005440), onSecondaryContainer = Color(0xFFCDF3E5),
    tertiary = Color(0xFFFFB86E), onTertiary = Color(0xFF4A2500),
    tertiaryContainer = Color(0xFF633100), onTertiaryContainer = Color(0xFFFFE8CC),
    background = Color(0xFF0E0E13), onBackground = Color(0xFFE6E6EE),
    surface = Color(0xFF0E0E13), onSurface = Color(0xFFE6E6EE),
    surfaceContainer = Color(0xFF191920), surfaceContainerHigh = Color(0xFF23232C),
    surfaceVariant = Color(0xFF2A2A34), onSurfaceVariant = Color(0xFFB3B3C3),
    outline = Color(0xFF6E6E7E), outlineVariant = Color(0xFF32323D),
)

/** Meter colors are fixed across themes so "green / amber / red" keeps its meaning. */
object MeterColors {
    val Low = Color(0xFF22C38E)
    val Mid = Color(0xFFF2C14E)
    val High = Color(0xFFEF5350)
}

@Composable
fun BridgeTheme(content: @Composable () -> Unit) {
    val base = Typography()
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) Dark else Light,
        typography = base.copy(
            headlineSmall = base.headlineSmall.copy(fontWeight = FontWeight.SemiBold),
            titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold),
            titleLarge = base.titleLarge.copy(fontWeight = FontWeight.SemiBold),
        ),
        content = content,
    )
}
