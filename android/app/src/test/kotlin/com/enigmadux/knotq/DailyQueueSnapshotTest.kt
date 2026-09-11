package com.enigmadux.knotq

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DailyQueueSnapshotTest {
    @Test
    fun findsOnlyAnExactDateAmongWellFormedCandidates() {
        val candidates = listOf(
            "2026-09-09",
            "2026-09-10",
            "2026-09-09T00:00:00Z",
        )

        assertTrue(containsExactDailyDate(candidates, "2026-09-09"))
        assertTrue(containsExactDailyDate(candidates, "2026-09-10"))
        assertFalse(containsExactDailyDate(candidates, "2026-09-11"))
    }

    @Test
    fun malformedCandidatesAreMissingRatherThanPartialMatches() {
        val malformed: List<String?> = listOf(
            null,
            "",
            "null",
            "2026-09-0",
            "2026-09-09T00:00:00Z",
        )

        assertFalse(containsExactDailyDate(malformed, "2026-09-09"))
    }

    @Test
    fun deterministicMalformedFuzzerNeverThrowsOrMatchesPartialDates() {
        var state = 0x1a2b3c4d
        fun next(): Int {
            state = state * 1664525 + 1013904223
            return state
        }

        repeat(4096) { caseIndex ->
            val day = (next().ushr(1) % 28) + 1
            val target = "2026-09-" + day.toString().padStart(2, '0')
            val candidates = buildList {
                repeat(next().ushr(27) and 31) {
                    add(
                        when (next().ushr(29) and 3) {
                            0 -> target
                            1 -> target.dropLast(1)
                            2 -> null
                            else -> "garbage-${next()}"
                        },
                    )
                }
            }
            val expected = candidates.any { it == target }
            assertTrue(
                "unexpected daily lookup at case=$caseIndex",
                containsExactDailyDate(candidates, target) == expected,
            )
        }
    }
}
