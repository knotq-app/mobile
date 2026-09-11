package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CalendarIntervalLayoutTest {
    @Test
    fun touchingIntervalsStayInOneLaneAndRestartComponents() {
        val placements = layoutCalendarIntervals(
            listOf(
                CalendarLayoutInterval(1, 0f, 30f),
                CalendarLayoutInterval(2, 30f, 60f),
                CalendarLayoutInterval(3, 120f, 150f),
            ),
        )

        assertEquals(listOf(1, 2, 3), placements.map { it.key })
        assertTrue(placements.all { it.lane == 0 && it.laneSpan == 1 && it.laneCount == 1 })
    }

    @Test
    fun connectedOverlapComponentUsesFreeLaneSpans() {
        val placements = layoutCalendarIntervals(
            listOf(
                CalendarLayoutInterval(1, 0f, 5f),
                CalendarLayoutInterval(2, 0f, 5f),
                CalendarLayoutInterval(3, 0f, 20f),
                // The short intervals have ended by this point, while the
                // long interval keeps the component connected. The new item
                // may therefore span the next free lane.
                CalendarLayoutInterval(4, 5f, 6f),
            ),
        ).associateBy { it.key }

        assertEquals(3, placements.getValue(4).laneCount)
        assertEquals(1, placements.getValue(4).lane)
        assertEquals(2, placements.getValue(4).laneSpan)
    }

    @Test
    fun malformedIntervalsAreIgnoredWithoutBreakingValidLayout() {
        val placements = layoutCalendarIntervals(
            listOf(
                CalendarLayoutInterval(1, Float.NaN, 20f),
                CalendarLayoutInterval(2, 20f, 20f),
                CalendarLayoutInterval(3, 50f, Float.POSITIVE_INFINITY),
                CalendarLayoutInterval(4, 10f, 30f),
            ),
        )

        assertEquals(listOf(4), placements.map { it.key })
    }

    @Test
    fun deterministicFuzzerPreservesLaneInvariants() {
        var state = 0x51f15e7
        fun next(): Int {
            state = state * 1664525 + 1013904223
            return state
        }
        fun overlaps(a: CalendarLayoutInterval, b: CalendarLayoutInterval): Boolean =
            a.startMin < b.endMin && b.startMin < a.endMin

        repeat(4096) { caseIndex ->
            val intervals = buildList {
                repeat((next() ushr 27) and 31) { key ->
                    val start = ((next() ushr 1) % 1440).toFloat()
                    val duration = 1f + ((next() ushr 1) % 240).toFloat()
                    add(CalendarLayoutInterval(key, start, (start + duration).coerceAtMost(1440f)))
                }
            }
            val placements = layoutCalendarIntervals(intervals)
            val byKey = intervals.associateBy { it.key }
            assertEquals("duplicate placement at case=$caseIndex", placements.size, placements.map { it.key }.toSet().size)
            placements.forEach { placement ->
                val interval = byKey.getValue(placement.key)
                assertTrue("negative lane at case=$caseIndex", placement.lane >= 0)
                assertTrue("invalid span at case=$caseIndex", placement.laneSpan >= 1)
                assertTrue(
                    "span exceeds lane count at case=$caseIndex",
                    placement.lane + placement.laneSpan <= placement.laneCount,
                )
                placements.forEach { other ->
                    if (placement.key == other.key) return@forEach
                    val otherInterval = byKey.getValue(other.key)
                    val sharedLane = placement.lane until (placement.lane + placement.laneSpan)
                    val otherLanes = other.lane until (other.lane + other.laneSpan)
                    assertTrue(
                        "overlap in shared lane at case=$caseIndex",
                        !overlaps(interval, otherInterval) || sharedLane.intersect(otherLanes).isEmpty(),
                    )
                }
            }
        }
    }

    @Test
    fun adversarialFuzzerIgnoresMalformedAndExtremeIntervals() {
        var state = 0x7f4a7c15
        fun next(): Int {
            state = state * 1664525 + 1013904223
            return state
        }
        fun overlaps(a: CalendarLayoutInterval, b: CalendarLayoutInterval): Boolean =
            a.startMin < b.endMin && b.startMin < a.endMin

        repeat(4096) { caseIndex ->
            val intervals = buildList {
                repeat((next() ushr 26) and 63) { key ->
                    val selector = next() ushr 29
                    val start = when (selector and 3) {
                        0 -> Float.NaN
                        1 -> Float.POSITIVE_INFINITY
                        2 -> -5000f + (next() % 9000).toFloat()
                        else -> (next() % 5000).toFloat()
                    }
                    val end = when ((selector ushr 2) and 3) {
                        0 -> start
                        1 -> start - 1f
                        2 -> Float.NEGATIVE_INFINITY
                        else -> start + 1f + (next() ushr 1 % 900).toFloat()
                    }
                    add(CalendarLayoutInterval(key, start, end))
                }
            }
            val valid = intervals.filter {
                it.startMin.isFinite() && it.endMin.isFinite() && it.endMin > it.startMin
            }
            val placements = layoutCalendarIntervals(intervals)
            val byKey = valid.associateBy { it.key }

            assertEquals("valid interval count at case=$caseIndex", valid.size, placements.size)
            assertEquals(
                "every valid interval placed exactly once at case=$caseIndex",
                valid.map { it.key }.toSet(),
                placements.map { it.key }.toSet(),
            )
            placements.forEach { placement ->
                val interval = byKey.getValue(placement.key)
                assertTrue("negative lane at case=$caseIndex", placement.lane >= 0)
                assertTrue("invalid span at case=$caseIndex", placement.laneSpan >= 1)
                assertTrue(
                    "span exceeds lane count at case=$caseIndex",
                    placement.lane + placement.laneSpan <= placement.laneCount,
                )
                placements.forEach { other ->
                    if (placement.key == other.key) return@forEach
                    val otherInterval = byKey.getValue(other.key)
                    val sharedLane = placement.lane until (placement.lane + placement.laneSpan)
                    val otherLanes = other.lane until (other.lane + other.laneSpan)
                    assertTrue(
                        "extreme overlap in shared lane at case=$caseIndex",
                        !overlaps(interval, otherInterval) || sharedLane.intersect(otherLanes).isEmpty(),
                    )
                }
            }
        }
    }
}
