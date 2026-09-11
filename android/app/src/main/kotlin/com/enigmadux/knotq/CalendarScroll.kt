package com.enigmadux.knotq

/**
 * Returns the first calendar scroll position for an hour-based timeline.
 *
 * Keep the hour label below the viewport edge instead of placing its baseline
 * at y=0. This is deliberately pure so density, midnight, and malformed input
 * can be exercised without constructing an Activity or a Canvas.
 */
internal fun calendarAnchorScrollY(
    hour: Int,
    hourHeightPx: Int,
    topOffsetPx: Int,
    labelClearancePx: Int,
): Int {
    if (hourHeightPx <= 0) return 0
    val safeHour = hour.coerceIn(0, 24)
    val safeTop = topOffsetPx.coerceAtLeast(0)
    val safeClearance = labelClearancePx.coerceAtLeast(0)
    return (safeTop + safeHour * hourHeightPx - safeClearance).coerceAtLeast(0)
}

/**
 * True when an event rectangle can intersect the currently visible timeline.
 * A one-pixel tolerance keeps an edge from disappearing while a ScrollView
 * reports adjacent integer offsets during a fling.
 */
internal fun calendarRectIntersectsViewport(
    rectTop: Float,
    rectBottom: Float,
    viewportTop: Int,
    viewportHeight: Int,
    edgePx: Float = 1f,
): Boolean {
    if (viewportHeight <= 0) return true
    if (!rectTop.isFinite() || !rectBottom.isFinite()) return false
    val edge = edgePx.coerceAtLeast(0f)
    val visibleTop = viewportTop.toFloat()
    val visibleBottom = viewportTop.toLong().plus(viewportHeight.toLong()).toFloat()
    return rectBottom >= visibleTop - edge && rectTop <= visibleBottom + edge
}
