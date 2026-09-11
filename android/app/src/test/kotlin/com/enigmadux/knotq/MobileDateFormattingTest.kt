package com.enigmadux.knotq

import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MobileDateFormattingTest {
    private val newYork = ZoneId.of("America/New_York")
    private val losAngeles = ZoneId.of("America/Los_Angeles")

    @Test
    fun isoConvertsLocalWallTimeToUtcAcrossDstGap() {
        // The nonexistent 02:30 wall time is resolved by java.time to 03:30
        // during the spring-forward transition, then converted to UTC.
        assertEquals(
            "2024-03-10T07:30:00Z",
            MobileDateFormatting.iso(LocalDate.of(2024, 3, 10), 2, 30, newYork),
        )
    }

    @Test
    fun displayTimeUsesTheViewerZoneAndHandlesDateBoundary() {
        val raw = "2024-01-01T00:30:00Z"
        assertEquals("4:30 PM", MobileDateFormatting.time(raw, false, losAngeles))
        assertEquals("16:30", MobileDateFormatting.time(raw, true, losAngeles))
        assertEquals(
            "Tomorrow",
            MobileDateFormatting.upcomingDatePrefix(
                Instant.parse(raw),
                losAngeles,
                LocalDate.of(2023, 12, 30),
            ),
        )
    }

    @Test
    fun fallBackInstantRemainsUnambiguous() {
        // Both 01:30 occurrences exist; formatting must follow the instant's
        // offset rather than treating the timestamp as a local string.
        assertEquals("1:30 AM", MobileDateFormatting.time("2024-11-03T05:30:00Z", false, newYork))
        assertEquals("1:30 AM", MobileDateFormatting.time("2024-11-03T06:30:00Z", false, newYork))
        assertEquals("2024-11-03T05:30:00Z", MobileDateFormatting.iso(LocalDate.of(2024, 11, 3), 1, 30, newYork))
    }

    @Test
    fun unchangedAmbiguousWallTimePreservesTheOriginalOffset() {
        val firstOccurrence = "2024-11-03T05:30:00Z" // 01:30 EDT
        val secondOccurrence = "2024-11-03T06:30:00Z" // 01:30 EST
        assertEquals(
            firstOccurrence,
            MobileDateFormatting.isoPreservingInstantWhenWallTimeUnchanged(
                firstOccurrence,
                LocalDate.of(2024, 11, 3),
                1,
                30,
                newYork,
            ),
        )
        assertEquals(
            secondOccurrence,
            MobileDateFormatting.isoPreservingInstantWhenWallTimeUnchanged(
                secondOccurrence,
                LocalDate.of(2024, 11, 3),
                1,
                30,
                newYork,
            ),
        )
    }

    @Test
    fun changingWallTimeReencodesAgainstTheCurrentZoneRules() {
        assertEquals(
            "2024-11-03T06:31:00Z",
            MobileDateFormatting.isoPreservingInstantWhenWallTimeUnchanged(
                "2024-11-03T06:30:00Z",
                LocalDate.of(2024, 11, 3),
                1,
                31,
                newYork,
            ),
        )
    }

    @Test
    fun malformedAndNullValuesStaySafe() {
        assertNull(MobileDateFormatting.parseInstant("not-an-instant"))
        assertEquals("not-an-instant", MobileDateFormatting.time("not-an-instant", false, newYork))
        assertEquals("", MobileDateFormatting.time(null, false, newYork))
    }

    @Test
    fun formatterUsesCurrentLocaleWithoutRebuildingForEveryRow() {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.US)
            assertEquals("4:30 PM", MobileDateFormatting.time("2024-01-01T00:30:00Z", false, losAngeles))
            Locale.setDefault(Locale.UK)
            assertEquals("4:30 pm", MobileDateFormatting.time("2024-01-01T00:30:00Z", false, losAngeles))
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test
    fun cachedLabelsRespectProcessTimezoneChanges() {
        val previousZone = TimeZone.getDefault()
        val previousLocale = Locale.getDefault()
        try {
            Locale.setDefault(Locale.US)
            TimeZone.setDefault(TimeZone.getTimeZone("America/Los_Angeles"))
            assertEquals(
                "At 4:30 PM",
                MobileDateFormatting.compactOccurrenceLabel(
                    "reminder", "2024-01-01T00:30:00Z", null, false,
                ),
            )

            // This is deliberately the same raw occurrence: a cache that omits
            // the active zone would incorrectly return the Los Angeles label.
            TimeZone.setDefault(TimeZone.getTimeZone("Pacific/Auckland"))
            assertEquals(
                "At 1:30 PM",
                MobileDateFormatting.compactOccurrenceLabel(
                    "reminder", "2024-01-01T00:30:00Z", null, false,
                ),
            )
        } finally {
            TimeZone.setDefault(previousZone)
            Locale.setDefault(previousLocale)
        }
    }

    @Test
    fun explicitCalendarZoneWinsEvenWhenProcessTimezoneChanges() {
        val previousZone = TimeZone.getDefault()
        val previousLocale = Locale.getDefault()
        try {
            Locale.setDefault(Locale.US)
            TimeZone.setDefault(TimeZone.getTimeZone("Pacific/Auckland"))
            assertEquals(
                "At 4:30 PM",
                MobileDateFormatting.compactOccurrenceLabel(
                    "reminder",
                    "2024-01-01T00:30:00Z",
                    null,
                    false,
                    zone = losAngeles,
                ),
            )
        } finally {
            TimeZone.setDefault(previousZone)
            Locale.setDefault(previousLocale)
        }
    }

    @Test
    fun isoRoundTripsWallTimeAcrossEveryAvailableZone() {
        // Exercise the full tzdb rather than only the zones used by the test
        // machine. ZonedDateTime.of applies the platform's documented gap/
        // overlap resolution; iso must preserve that resolved local value.
        val dates = listOf(
            LocalDate.of(2024, 3, 10),
            LocalDate.of(2024, 10, 27),
            LocalDate.of(2024, 11, 3),
        )
        val times = listOf(
            LocalTime.MIDNIGHT,
            LocalTime.of(1, 30),
            LocalTime.of(2, 30),
            LocalTime.NOON,
            LocalTime.of(23, 59),
        )
        ZoneId.getAvailableZoneIds().sorted().forEach { zoneId ->
            val zone = ZoneId.of(zoneId)
            dates.forEach { date ->
                times.forEach { time ->
                    val expected = ZonedDateTime.of(date, time, zone)
                    val encoded = MobileDateFormatting.iso(date, time.hour, time.minute, zone)
                    val actual = Instant.parse(encoded).atZone(zone)
                    assertEquals("date zone=$zoneId date=$date time=$time", expected.toLocalDate(), actual.toLocalDate())
                    assertEquals("time zone=$zoneId date=$date time=$time", expected.toLocalTime(), actual.toLocalTime())
                }
            }
        }
    }

    @Test
    fun deterministicMalformedTimestampFuzzerNeverThrows() {
        // Keep this dependency-free and reproducible: production data can come
        // from sync/import payloads, so every formatter entry point must treat
        // arbitrary strings as displayable bad data rather than crashing a
        // render. The seed is fixed so a failure is immediately replayable.
        var state = 0x6d2b79f5
        repeat(4096) {
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
            MobileDateFormatting.parseInstant(raw)
            MobileDateFormatting.time(raw, false, newYork)
            MobileDateFormatting.compactEventTime(raw, true, includePeriod = true, zone = losAngeles)
            MobileDateFormatting.occurrenceLabel(raw, raw, raw, false)
            MobileDateFormatting.occurrenceLabel(raw, raw, raw, true, showDay = true)
            MobileDateFormatting.compactOccurrenceLabel(raw, raw, raw, false)
            MobileDateFormatting.compactOccurrenceLabel(raw, raw, raw, true)
            MobileDateFormatting.isCompactEvent(raw, raw, raw)
        }
    }

    @Test
    fun formatterCachesRemainDeterministicUnderConcurrentRedrawLoad() {
        // Calendar/Home redraws and background refresh completion can reach
        // formatting through different threads. Exercise the shared bounded
        // caches concurrently so a harmless-looking cache optimization cannot
        // become a race, stale label, or sporadic render exception.
        val raw = "2024-11-03T05:30:00Z"
        val zones = listOf(
            ZoneId.of("UTC"),
            ZoneId.of("America/New_York"),
            ZoneId.of("America/Los_Angeles"),
            ZoneId.of("Pacific/Auckland"),
            ZoneId.of("Asia/Kolkata"),
            ZoneId.of("Australia/Lord_Howe"),
        )
        val expected = zones.associateWith { zone ->
            listOf(
                MobileDateFormatting.time(raw, false, zone),
                MobileDateFormatting.time(raw, true, zone),
                MobileDateFormatting.compactEventTime(raw, false, true, zone),
                MobileDateFormatting.compactEventTime(raw, true, false, zone),
                MobileDateFormatting.iso(LocalDate.of(2024, 11, 3), 1, 30, zone),
            )
        }
        val executor = Executors.newFixedThreadPool(8)
        try {
            val jobs = (0 until 8).map { worker ->
                Callable {
                    repeat(1_000) { iteration ->
                        val zone = zones[(worker * 31 + iteration) % zones.size]
                        val values = expected.getValue(zone)
                        assertEquals(values[0], MobileDateFormatting.time(raw, false, zone))
                        assertEquals(values[1], MobileDateFormatting.time(raw, true, zone))
                        assertEquals(
                            values[2],
                            MobileDateFormatting.compactEventTime(raw, false, true, zone),
                        )
                        assertEquals(
                            values[3],
                            MobileDateFormatting.compactEventTime(raw, true, false, zone),
                        )
                        assertEquals(
                            values[4],
                            MobileDateFormatting.iso(LocalDate.of(2024, 11, 3), 1, 30, zone),
                        )
                        check(MobileDateFormatting.parseInstant(raw) != null)
                    }
                }
            }
            executor.invokeAll(jobs).forEach { it.get(20, TimeUnit.SECONDS) }
        } finally {
            executor.shutdownNow()
        }
    }
}
