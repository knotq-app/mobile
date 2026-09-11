package com.enigmadux.knotq

/** Returns a saved scroll offset clamped to the currently available content. */
internal fun restoredScrollOffset(savedY: Int, contentHeight: Int, viewportHeight: Int): Int {
    val maximum = (contentHeight - viewportHeight).coerceAtLeast(0)
    return savedY.coerceIn(0, maximum)
}
