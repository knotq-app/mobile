package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UiMotionTest {
    @Test
    fun zeroSystemScaleDisablesMotionCompletely() {
        assertEquals(0L, scaledAnimationDuration(220L, 0f))
        assertEquals(0L, scaledAnimationDuration(1L, 0f))
    }

    @Test
    fun normalScalePreservesBaseDuration() {
        assertEquals(220L, scaledAnimationDuration(220L, 1f))
    }

    @Test
    fun fractionalScaleRoundsWithoutCreatingZeroDuration() {
        assertEquals(110L, scaledAnimationDuration(220L, 0.5f))
        assertEquals(1L, scaledAnimationDuration(1L, 0.01f))
    }

    @Test
    fun invalidScaleFailsSafeToNoMotion() {
        assertEquals(0L, scaledAnimationDuration(220L, Float.NaN))
        assertEquals(0L, scaledAnimationDuration(220L, Float.POSITIVE_INFINITY))
        assertEquals(0L, scaledAnimationDuration(220L, -1f))
    }

    @Test
    fun extremeDurationsNeverWrapNegative() {
        assertEquals(Long.MAX_VALUE, scaledAnimationDuration(Long.MAX_VALUE, 2f))
        assertEquals(1L, scaledAnimationDuration(1L, Float.MIN_VALUE))
    }

    @Test
    fun pageSnapsAreDistanceAwareButAlwaysBounded() {
        assertEquals(205L, snappingAnimationDurationMs(205L, 480f, 480f))
        assertEquals(120L, snappingAnimationDurationMs(205L, 1f, 480f))
        assertEquals(120L, snappingAnimationDurationMs(165L, 1f, 480f))
        assertEquals(0L, snappingAnimationDurationMs(205L, 240f, 0f))
        assertEquals(0L, snappingAnimationDurationMs(205L, Float.NaN, 480f))
        assertEquals(0L, snappingAnimationDurationMs(205L, 240f, Float.POSITIVE_INFINITY))
    }

    @Test
    fun deterministicSnapDurationFuzzerNeverEscapesBounds() {
        var state = 0x13579bdf
        fun next(): Int {
            state = state * 1664525 + 1013904223
            return state
        }

        repeat(8192) {
            val base = (next().ushr(1) % 2_000L + 1L)
            val distance = when (next().ushr(29) and 7) {
                0 -> Float.NaN
                1 -> Float.POSITIVE_INFINITY
                2 -> Float.NEGATIVE_INFINITY
                else -> (next() % 2_000_000).toFloat()
            }
            val width = when (next().ushr(29) and 7) {
                0 -> 0f
                1 -> Float.NaN
                2 -> Float.POSITIVE_INFINITY
                else -> (next().ushr(1) % 2_000 + 1).toFloat()
            }
            val duration = snappingAnimationDurationMs(base, distance, width)
            assertTrue("duration=$duration base=$base distance=$distance width=$width", duration >= 0L)
            assertTrue("duration=$duration base=$base", duration <= base)
            if (!distance.isFinite() || !width.isFinite() || width <= 0f) {
                assertEquals(0L, duration)
            } else {
                assertTrue("duration=$duration", duration >= minOf(120L, base))
            }
        }
    }

    @Test
    fun deterministicScaleFuzzerNeverProducesAnInvalidDuration() {
        var state = 0x6d2b79f5
        fun next(): Int {
            state = state * 1664525 + 1013904223
            return state
        }

        repeat(8192) {
            val base = (next().ushr(1) % 60_000).toLong()
            val scale = when (next().ushr(29) and 7) {
                0 -> Float.NaN
                1 -> Float.POSITIVE_INFINITY
                2 -> Float.NEGATIVE_INFINITY
                3 -> -Float.MIN_VALUE
                4 -> Float.MIN_VALUE
                else -> (next().ushr(1) % 5000).toFloat() / 100f
            }
            val duration = scaledAnimationDuration(base, scale)
            assertTrue("negative duration=$duration base=$base scale=$scale", duration >= 0L)
            if (!scale.isFinite() || scale <= 0f || base == 0L) {
                assertEquals(0L, duration)
            } else {
                assertTrue(duration >= 1L)
            }
        }
    }

    @Test
    fun calendarSwipeUsesProjectionAndRejectsInvalidGeometry() {
        assertEquals(1L, calendarDaySwipeDelta(-240f, 0f, 480f, 960f, 48f))
        assertEquals(-1L, calendarDaySwipeDelta(240f, 0f, 480f, 960f, 48f))
        assertEquals(1L, calendarDaySwipeDelta(-20f, -1_500f, 480f, 960f, 48f))
        assertEquals(0L, calendarDaySwipeDelta(30f, 0f, 480f, 960f, 48f))
        assertEquals(0L, calendarDaySwipeDelta(Float.NaN, 0f, 480f, 960f, 48f))
        assertEquals(0L, calendarDaySwipeDelta(100f, Float.POSITIVE_INFINITY, 480f, 960f, 48f))
        assertEquals(0L, calendarDaySwipeDelta(100f, 0f, 0f, 960f, 48f))
        assertEquals(0L, calendarDaySwipeDelta(100f, 0f, 480f, Float.POSITIVE_INFINITY, 48f))
    }

    @Test
    fun deterministicCalendarSwipeFuzzerAlwaysReturnsAValidPageDelta() {
        var state = 0x2468ace1
        fun next(): Int {
            state = state * 1664525 + 1013904223
            return state
        }

        repeat(8192) {
            val offset = when (next().ushr(29) and 7) {
                0 -> Float.NaN
                1 -> Float.POSITIVE_INFINITY
                2 -> Float.NEGATIVE_INFINITY
                else -> (next() % 2_000_000).toFloat()
            }
            val velocity = when (next().ushr(29) and 7) {
                0 -> Float.NaN
                1 -> Float.POSITIVE_INFINITY
                2 -> Float.NEGATIVE_INFINITY
                else -> (next() % 4_000_000).toFloat()
            }
            val column = when (next().ushr(29) and 7) {
                0 -> 0f
                1 -> Float.NaN
                2 -> Float.POSITIVE_INFINITY
                else -> (next().ushr(1) % 2_000 + 1).toFloat()
            }
            val viewport = when (next().ushr(29) and 7) {
                0 -> 0f
                1 -> Float.NaN
                2 -> Float.POSITIVE_INFINITY
                else -> (next().ushr(1) % 4_000 + 1).toFloat()
            }
            val delta = calendarDaySwipeDelta(offset, velocity, column, viewport, 48f)
            assertTrue("invalid page delta=$delta", delta in -1L..1L)
            if (!offset.isFinite() || !velocity.isFinite() || !column.isFinite() || !viewport.isFinite() || column <= 0f || viewport <= 0f) {
                assertEquals(0L, delta)
            }
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun negativeBaseDurationIsRejected() {
        scaledAnimationDuration(-1L, 1f)
    }
}
