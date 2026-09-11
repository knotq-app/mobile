package com.enigmadux.knotq

/** A normalized interval used by the calendar's greedy overlap layout. */
internal data class CalendarLayoutInterval(
    val key: Int,
    val startMin: Float,
    val endMin: Float,
)

/** The horizontal lane assignment for one [CalendarLayoutInterval]. */
internal data class CalendarLayoutPlacement(
    val key: Int,
    val lane: Int,
    val laneSpan: Int,
    val laneCount: Int,
)

/**
 * Assigns overlapping intervals to the smallest possible set of lanes.
 *
 * Intervals that only touch at an endpoint do not overlap. Independent overlap
 * components restart at lane zero, and an interval spans adjacent lanes when
 * none of those lanes contain an overlapping item. Invalid/non-finite input is
 * ignored so malformed imported data cannot break a calendar draw pass.
 */
internal fun layoutCalendarIntervals(
    input: List<CalendarLayoutInterval>,
): List<CalendarLayoutPlacement> {
    val intervals = input
        .filter { it.startMin.isFinite() && it.endMin.isFinite() && it.endMin > it.startMin }
        .sortedWith(compareBy<CalendarLayoutInterval> { it.startMin }.thenByDescending { it.endMin })

    data class Pending(val interval: CalendarLayoutInterval, val lane: Int)
    data class Placed(val interval: CalendarLayoutInterval, val lane: Int, val span: Int, val count: Int)

    fun overlaps(a: CalendarLayoutInterval, b: CalendarLayoutInterval): Boolean =
        a.startMin < b.endMin && b.startMin < a.endMin

    fun flush(component: ArrayList<Pending>, output: ArrayList<Placed>) {
        if (component.isEmpty()) return
        val laneCount = component.maxOf { it.lane } + 1
        component.forEach { pending ->
            var span = 1
            for (lane in (pending.lane + 1) until laneCount) {
                if (component.any { other ->
                        other.lane == lane && overlaps(pending.interval, other.interval)
                    }) {
                    break
                }
                span += 1
            }
            output.add(Placed(pending.interval, pending.lane, span, laneCount))
        }
        component.clear()
    }

    val component = ArrayList<Pending>(intervals.size)
    val output = ArrayList<Placed>(intervals.size)
    var componentEnd = Float.NEGATIVE_INFINITY
    val active = ArrayList<Pair<Float, Int>>()

    intervals.forEach { interval ->
        if (component.isNotEmpty() && interval.startMin >= componentEnd) {
            flush(component, output)
            active.clear()
            componentEnd = Float.NEGATIVE_INFINITY
        }
        active.removeAll { it.first <= interval.startMin }
        var lane = 0
        while (active.any { it.second == lane }) lane += 1
        active.add(interval.endMin to lane)
        componentEnd = maxOf(componentEnd, interval.endMin)
        component.add(Pending(interval, lane))
    }
    flush(component, output)

    return output.map { placed ->
        CalendarLayoutPlacement(
            key = placed.interval.key,
            lane = placed.lane,
            laneSpan = placed.span,
            laneCount = placed.count,
        )
    }
}
