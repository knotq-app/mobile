package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CalendarScrollTest {
    @Test
    fun initialHourLeavesLabelClearanceBelowViewportEdge() {
        assertEquals(
            74,
            calendarAnchorScrollY(hour = 2, hourHeightPx = 44, topOffsetPx = 8, labelClearancePx = 22),
        )
    }

    @Test
    fun midnightNeverScrollsBeforeTimelineStart() {
        assertEquals(
            0,
            calendarAnchorScrollY(hour = 0, hourHeightPx = 44, topOffsetPx = 8, labelClearancePx = 22),
        )
    }

    @Test
    fun deterministicAnchorFuzzerNeverReturnsInvalidOrNegativeScroll() {
        var state = 0x4f1bbcdc
        fun next(): Int {
            state = state * 1664525 + 1013904223
            return state
        }

        repeat(16_384) {
            val hour = when (next() ushr 29) {
                0 -> Int.MIN_VALUE
                1 -> Int.MAX_VALUE
                else -> next()
            }
            val hourHeight = when (next() ushr 29) {
                0 -> Int.MIN_VALUE
                1 -> 0
                else -> next()
            }
            val top = next()
            val clearance = next()
            val actual = calendarAnchorScrollY(hour, hourHeight, top, clearance)
            assertTrue("negative anchor=$actual", actual >= 0)
            if (hourHeight <= 0) assertEquals(0, actual)
        }
    }

    @Test
    fun viewportCullingKeepsEdgesAndRejectsClearlyOffscreenEvents() {
        assertTrue(calendarRectIntersectsViewport(100f, 120f, 100, 300))
        assertTrue(calendarRectIntersectsViewport(399f, 400f, 100, 300))
        assertTrue(calendarRectIntersectsViewport(99f, 100f, 100, 300))
        assertFalse(calendarRectIntersectsViewport(0f, 98.5f, 100, 300))
        assertFalse(calendarRectIntersectsViewport(401.5f, 450f, 100, 300))
        assertTrue(calendarRectIntersectsViewport(10f, 20f, 100, 0))
        assertFalse(calendarRectIntersectsViewport(Float.NaN, 20f, 100, 300))
        assertFalse(calendarRectIntersectsViewport(10f, Float.POSITIVE_INFINITY, 100, 300))
    }

    @Test
    fun deterministicViewportFuzzerMatchesIntervalIntersection() {
        var state = 0x73a91e2b
        fun next(): Int {
            state = state * 1664525 + 1013904223
            return state
        }

        repeat(16_384) {
            val viewportTop = next() ushr 1
            val viewportHeight = (next() ushr 1) % 2_000
            val top = (next() % 4_000).toFloat()
            val bottom = top + (next() ushr 1) % 500
            val actual = calendarRectIntersectsViewport(top, bottom, viewportTop, viewportHeight)
            val visibleTop = viewportTop.toFloat()
            val visibleBottom = viewportTop.toLong().plus(viewportHeight.toLong()).toFloat()
            val expected = viewportHeight <= 0 ||
                (bottom >= visibleTop - 1f && top <= visibleBottom + 1f)
            assertEquals("iteration=$it", expected, actual)
        }
    }
}
