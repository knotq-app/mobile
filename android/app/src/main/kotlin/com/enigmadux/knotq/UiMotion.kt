package com.enigmadux.knotq

import android.content.Context
import android.provider.Settings
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * Keeps app-authored motion aligned with Android's accessibility/developer
 * animation setting. In particular, a scale of zero must be a true no-motion
 * path rather than a one-frame animation that can flash during a rebuild.
 */
internal fun scaledAnimationDuration(baseMs: Long, systemScale: Float): Long {
    require(baseMs >= 0) { "base animation duration must be non-negative" }
    if (!systemScale.isFinite() || systemScale <= 0f || baseMs == 0L) return 0L
    return (baseMs.toDouble() * systemScale.toDouble())
        .roundToLong()
        .coerceAtLeast(1L)
}

internal fun animationDuration(context: Context, baseMs: Long): Long {
    val scale = runCatching {
        Settings.Global.getFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        )
    }.getOrDefault(1f)
    return scaledAnimationDuration(baseMs, scale)
}

/**
 * Keeps a page snap quick without making a short, interrupted drag feel like
 * it teleports. The lower bound is important for accessibility settings and
 * tiny distances; the finite/positive checks keep bad layout data on the
 * no-motion path instead of feeding NaN or infinity into ValueAnimator.
 */
internal fun snappingAnimationDurationMs(
    baseMs: Long,
    distancePx: Float,
    pageWidthPx: Float,
    minimumMs: Long = 120L,
): Long {
    require(baseMs >= 0) { "base animation duration must be non-negative" }
    require(minimumMs >= 0) { "minimum animation duration must be non-negative" }
    if (
        baseMs == 0L ||
        !distancePx.isFinite() ||
        !pageWidthPx.isFinite() ||
        pageWidthPx <= 0f
    ) return 0L

    val minimum = minimumMs.coerceAtMost(baseMs)
    val fraction = (abs(distancePx) / pageWidthPx).coerceIn(0.35f, 1f)
    return (baseMs.toDouble() * fraction.toDouble())
        .roundToLong()
        .coerceIn(minimum, baseMs)
}

/**
 * Chooses the adjacent calendar page for a completed horizontal swipe. Keep
 * this decision separate from the View/VelocityTracker code so malformed or
 * sparse gesture samples cannot turn into a bogus page change. A negative
 * result moves backward, a positive result moves forward, and zero springs
 * the current page back into place.
 */
internal fun calendarDaySwipeDelta(
    offsetPx: Float,
    velocityPxPerSecond: Float,
    columnWidthPx: Float,
    viewportWidthPx: Float,
    minimumThresholdPx: Float,
    projectionSeconds: Float = 0.18f,
): Long {
    require(minimumThresholdPx >= 0f) { "minimum swipe threshold must be non-negative" }
    require(projectionSeconds >= 0f) { "swipe projection must be non-negative" }
    if (
        !offsetPx.isFinite() ||
        !velocityPxPerSecond.isFinite() ||
        !columnWidthPx.isFinite() ||
        !viewportWidthPx.isFinite() ||
        !minimumThresholdPx.isFinite() ||
        !projectionSeconds.isFinite() ||
        columnWidthPx <= 0f ||
        viewportWidthPx <= 0f
    ) return 0L

    val projectedRaw = offsetPx + velocityPxPerSecond * projectionSeconds
    val projected = if (projectedRaw.isFinite() && abs(projectedRaw) > abs(offsetPx)) {
        projectedRaw
    } else {
        offsetPx
    }
    val threshold = max(
        minimumThresholdPx,
        min(viewportWidthPx * 0.15f, columnWidthPx * 0.68f),
    )
    val shouldShift = abs(projected) > threshold || abs(offsetPx) > columnWidthPx * 0.42f
    return when {
        shouldShift && projected < 0f -> 1L
        shouldShift && projected > 0f -> -1L
        else -> 0L
    }
}
