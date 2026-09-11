package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationLeadTimesTest {
    @Test
    fun knownOffsetsKeepTheirStableLabels() {
        assertEquals("At time", notificationLeadTimeLabel(0))
        assertEquals("At start", notificationLeadTimeLabel(0, eventDefault = true))
        assertEquals("At due time", notificationLeadTimeLabel(0, eventDefault = false))
        assertEquals("5 minutes before", notificationLeadTimeLabel(5 * 60))
        assertEquals("2 hours before", notificationLeadTimeLabel(2 * 60 * 60))
    }

    @Test
    fun extremeIntegerOffsetsNeverOverflowOrThrow() {
        val extremes = listOf(Int.MIN_VALUE, -1, 1, Int.MAX_VALUE)
        extremes.forEach { offset ->
            val label = notificationLeadTimeLabel(offset)
            assertTrue("offset=$offset label=$label", label.isNotBlank())
            assertTrue("offset=$offset label=$label", label.endsWith(if (offset > 0) "before" else "after"))
            val options = occurrenceNotificationOptionsIncluding(offset)
            assertTrue(options.zipWithNext().all { (left, right) -> left.offsetSecs <= right.offsetSecs })
            assertEquals(1, options.count { it.offsetSecs == offset })
        }
    }

    @Test
    fun deterministicOffsetFuzzerPreservesOrderingAndCustomValue() {
        var state = 0x13579bdf
        repeat(8192) {
            state = state * 1664525 + 1013904223
            val offset = state
            val label = notificationLeadTimeLabel(offset)
            assertTrue(label.isNotBlank())
            val options = occurrenceNotificationOptionsIncluding(offset)
            assertTrue(options.zipWithNext().all { (left, right) -> left.offsetSecs <= right.offsetSecs })
            assertEquals(1, options.count { it.offsetSecs == offset })
        }
    }
}
