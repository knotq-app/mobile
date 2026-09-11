package com.enigmadux.knotq

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileRecurrenceTest {
    @Test
    fun repeatChoicesAreCaseInsensitiveAndPrefixTolerant() {
        assertEquals("daily", MobileRecurrence.repeatChoiceFromRrule("rrule:freq=daily"))
        assertEquals("weekly", MobileRecurrence.repeatChoiceFromRrule("FREQ=WEEKLY;BYDAY=MO"))
        assertEquals("monthly", MobileRecurrence.repeatChoiceFromRrule("freq=monthly"))
        assertEquals("yearly", MobileRecurrence.repeatChoiceFromRrule("FREQ=YEARLY"))
        assertEquals("none", MobileRecurrence.repeatChoiceFromRrule(null))
        assertEquals("none", MobileRecurrence.repeatChoiceFromRrule("not-a-rule"))
    }

    @Test
    fun selectedWeekdaysHandlesOrdinalsWhitespaceAndFallbacks() {
        val fallback = LocalDate.of(2024, 1, 1) // Monday
        assertEquals(setOf("MO"), MobileRecurrence.selectedWeekdays(null, fallback))
        assertEquals(
            setOf("MO", "WE", "SU"),
            MobileRecurrence.selectedWeekdays("RRULE:FREQ=MONTHLY;BYDAY=1MO, WE, -1SU", fallback),
        )
        assertEquals(setOf("MO"), MobileRecurrence.selectedWeekdays("FREQ=WEEKLY;BYDAY=??", fallback))
    }

    @Test
    fun weeklyRulesAreStableAndNeverEmpty() {
        val date = LocalDate.of(2024, 1, 7) // Sunday
        assertEquals("FREQ=DAILY;INTERVAL=1", MobileRecurrence.rruleForRepeat("daily", date))
        assertEquals("FREQ=WEEKLY;INTERVAL=1;BYDAY=SU", MobileRecurrence.rruleForRepeat("weekly", date))
        assertEquals(
            "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,FR,SU",
            MobileRecurrence.rruleForRepeat("weekly", date, setOf("SU", "MO", "FR")),
        )
        assertEquals(null, MobileRecurrence.rruleForRepeat("none", date))
    }

    @Test
    fun arbitraryRuleTextAndDateExtremesNeverThrow() {
        var state = 0x2468ace1
        repeat(8192) {
            state = state xor (state shl 13)
            state = state xor (state ushr 17)
            state = state xor (state shl 5)
            val length = (state ushr 26) and 0x3f
            val raw = buildString(length) {
                repeat(length) {
                    state = state * 1664525 + 1013904223
                    append(('!'.code + ((state ushr 1) % 94)).toChar())
                }
            }
            val day = when ((state ushr 28) and 3) {
                0 -> LocalDate.MIN
                1 -> LocalDate.MAX
                2 -> LocalDate.of(2000, 2, 29)
                else -> LocalDate.ofEpochDay((state % 500_000).toLong())
            }
            val choice = MobileRecurrence.repeatChoiceFromRrule(raw)
            assertTrue(choice in setOf("none", "daily", "weekly", "monthly", "yearly"))
            assertTrue(MobileRecurrence.selectedWeekdays(raw, day).all { it in MobileRecurrence.weekdayCodes })
            MobileRecurrence.rruleForRepeat(raw, day, MobileRecurrence.weekdayCodes.toSet())
        }
    }
}
