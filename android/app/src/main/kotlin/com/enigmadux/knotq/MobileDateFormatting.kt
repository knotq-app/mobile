package com.enigmadux.knotq

import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.LinkedHashMap
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

internal object MobileDateFormatting {
    private val formatterCache = ConcurrentHashMap<Pair<String, Locale>, DateTimeFormatter>()
    private val instantCache = object : LinkedHashMap<String, Instant>(128, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Instant>?): Boolean = size > 512
    }
    // Home redraws can revisit the same upcoming rows several times while sync,
    // lifecycle, or theme state settles. Keep the complete display string too,
    // so a redraw does not repeatedly parse and zone-convert the same pair of
    // timestamps on the UI thread.
    private val occurrenceLabelCache = object : LinkedHashMap<String, String>(128, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?): Boolean = size > 512
    }
    // Calendar timeline rows are redrawn while scrolling and during day-swipe
    // motion. Cache the compact label separately because its event formatting
    // rules differ from the Home/upcoming label.
    private val compactOccurrenceLabelCache = object : LinkedHashMap<String, String>(128, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?): Boolean = size > 512
    }

    private fun formatter(pattern: String): DateTimeFormatter {
        val locale = Locale.getDefault()
        return formatterCache.getOrPut(pattern to locale) {
            DateTimeFormatter.ofPattern(pattern, locale)
        }
    }

    fun parseInstant(raw: String?): Instant? {
        if (raw.isNullOrEmpty() || raw == "null") return null
        synchronized(instantCache) {
            instantCache[raw]?.let { return it }
        }
        val parsed = runCatching { Instant.parse(raw) }.getOrNull() ?: return null
        synchronized(instantCache) {
            instantCache[raw] = parsed
        }
        return parsed
    }

    fun localDateTime(raw: String?, zone: ZoneId = ZoneId.systemDefault()): ZonedDateTime? =
        parseInstant(raw)?.atZone(zone)

    fun iso(
        date: LocalDate,
        hour: Int,
        minute: Int,
        zone: ZoneId = ZoneId.systemDefault(),
    ): String =
        ZonedDateTime.of(date, LocalTime.of(hour, minute), zone)
            .withZoneSameInstant(ZoneOffset.UTC)
            .format(DateTimeFormatter.ISO_INSTANT)

    /**
     * Encodes an edited local wall time while retaining an existing instant
     * when the visible fields were not changed. This matters during a DST
     * overlap: `2024-11-03 01:30` occurs twice, and reconstructing it with
     * `ZonedDateTime.of` alone chooses one offset and can silently move the
     * user's event by an hour.
     */
    fun isoPreservingInstantWhenWallTimeUnchanged(
        existingRaw: String?,
        date: LocalDate,
        hour: Int,
        minute: Int,
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        val existing = localDateTime(existingRaw, zone)
        if (existing != null &&
            existing.toLocalDate() == date &&
            existing.hour == hour &&
            existing.minute == minute
        ) {
            return existingRaw ?: existing.toInstant().toString()
        }
        // If the user edits within an ambiguous fall-back hour, keep the side
        // of the overlap they were already viewing. The offset is only reused
        // when it is valid for the new local time; gaps and ordinary times use
        // the platform's normal zone-rule resolution below.
        val local = LocalDateTime.of(date, LocalTime.of(hour, minute))
        val preferredOffset = existing?.offset?.takeIf { it in zone.rules.getValidOffsets(local) }
        if (preferredOffset != null) {
            return ZonedDateTime.ofLocal(local, zone, preferredOffset)
                .toInstant()
                .toString()
        }
        return iso(date, hour, minute, zone)
    }

    fun shortDay(raw: String): String =
        runCatching {
            val date = LocalDate.parse(raw)
            "${date.month.getDisplayName(TextStyle.SHORT, Locale.getDefault())} ${date.dayOfMonth}"
        }.getOrDefault(raw)

    fun fullDay(raw: String): String =
        runCatching {
            val date = LocalDate.parse(raw)
            "${date.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.getDefault())}, ${date.month.getDisplayName(TextStyle.SHORT, Locale.getDefault())} ${date.dayOfMonth}"
        }.getOrDefault(raw)

    fun month(raw: String): String =
        runCatching {
            val date = LocalDate.parse(raw)
            "${date.month.getDisplayName(TextStyle.FULL, Locale.getDefault())} ${date.year}"
        }.getOrDefault("Week")

    fun time(
        raw: String?,
        twentyFourHour: Boolean,
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        val instant = parseInstant(raw) ?: return raw?.takeIf { it != "null" }.orEmpty()
        val pattern = if (twentyFourHour) "HH:mm" else "h:mm a"
        return formatter(pattern).format(instant.atZone(zone))
    }

    fun compactEventTime(
        raw: String?,
        twentyFourHour: Boolean,
        includePeriod: Boolean,
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        val instant = parseInstant(raw) ?: return raw?.takeIf { it != "null" }.orEmpty()
        val pattern = if (twentyFourHour) "HH:mm" else if (includePeriod) "h:mm a" else "h:mm"
        return formatter(pattern).format(instant.atZone(zone))
    }

    fun occurrenceLabel(
        occurrence: JSONObject,
        twentyFourHour: Boolean,
        fallbackToKind: Boolean = true,
        showDay: Boolean = false
    ): String = occurrenceLabel(
        kind = occurrence.optString("kind"),
        startRaw = occurrence.optionalString("start"),
        endRaw = occurrence.optionalString("end"),
        twentyFourHour = twentyFourHour,
        fallbackToKind = fallbackToKind,
        showDay = showDay,
    )

    /** Pure value overload used by formatters and JVM fuzz tests. */
    fun occurrenceLabel(
        kind: String,
        startRaw: String?,
        endRaw: String?,
        twentyFourHour: Boolean,
        fallbackToKind: Boolean = true,
        showDay: Boolean = false,
    ): String {
        val zone = ZoneId.systemDefault()
        val key = listOf(
            kind,
            startRaw.orEmpty(),
            endRaw.orEmpty(),
            twentyFourHour,
            fallbackToKind,
            showDay,
            zone.id,
            Locale.getDefault().toLanguageTag(),
            if (showDay) LocalDate.now(zone).toString() else "",
        ).joinToString("\u0000")
        synchronized(occurrenceLabelCache) {
            occurrenceLabelCache[key]?.let { return it }
        }
        val result = if (showDay) {
            occurrenceLabelWithDay(kind, startRaw, endRaw, twentyFourHour, zone)
        } else {
            val start = time(startRaw, twentyFourHour, zone)
            val end = time(endRaw, twentyFourHour, zone)
            when {
                kind == "reminder" && start.isNotEmpty() -> "At $start"
                kind == "assignment" && end.isNotEmpty() -> "Due $end"
                start.isNotEmpty() && end.isNotEmpty() -> "$start - $end"
                start.isNotEmpty() -> start
                end.isNotEmpty() -> "Due $end"
                fallbackToKind -> kind.replaceFirstChar(Char::titlecase)
                else -> ""
            }
        }
        synchronized(occurrenceLabelCache) {
            occurrenceLabelCache[key] = result
        }
        return result
    }

    /// "Tomorrow", a near-week weekday ("Thu"), or "Jun 18" for dates past a
    /// week out; empty for today. Mirrors iOS `upcomingDatePrefix`.
    fun upcomingDatePrefix(
        instant: Instant,
        zone: ZoneId = ZoneId.systemDefault(),
        today: LocalDate = LocalDate.now(zone),
    ): String {
        val target = instant.atZone(zone).toLocalDate()
        if (target == today) return ""
        if (target == today.plusDays(1)) return "Tomorrow"
        if (target.isAfter(today) && target.isBefore(today.plusDays(7))) {
            return target.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.US)
        }
        return "${target.month.getDisplayName(TextStyle.SHORT, Locale.US)} ${target.dayOfMonth}"
    }

    private fun occurrenceLabelWithDay(
        kind: String,
        startRaw: String?,
        endRaw: String?,
        twentyFourHour: Boolean,
        zone: ZoneId,
    ): String {
        val startInstant = parseInstant(startRaw)
        val endInstant = parseInstant(endRaw)
        val start = formatTime(startInstant, startRaw, twentyFourHour, zone)
        val end = formatTime(endInstant, endRaw, twentyFourHour, zone)
        if (kind == "reminder" && startInstant != null && start.isNotEmpty()) {
            val day = upcomingDatePrefix(startInstant, zone)
            return if (day.isEmpty()) "At $start" else "At $day $start"
        }
        if (kind == "assignment" && endInstant != null && end.isNotEmpty()) {
            val day = upcomingDatePrefix(endInstant, zone)
            return if (day.isEmpty()) "Due $end" else "Due $day $end"
        }
        if (startInstant != null && endInstant != null && start.isNotEmpty() && end.isNotEmpty()) {
            val from = upcomingDatePrefix(startInstant, zone)
            val to = upcomingDatePrefix(endInstant, zone)
            val fromText = if (from.isEmpty()) start else "$from $start"
            val toText = if (from == to) end else if (to.isEmpty()) end else "$to $end"
            return "$fromText – $toText"
        }
        if (startInstant != null && start.isNotEmpty()) {
            val day = upcomingDatePrefix(startInstant, zone)
            return if (day.isEmpty()) start else "$day $start"
        }
        if (endInstant != null && end.isNotEmpty()) {
            val day = upcomingDatePrefix(endInstant, zone)
            return if (day.isEmpty()) "Due $end" else "Due $day $end"
        }
        return kind.replaceFirstChar(Char::titlecase)
    }

    private fun formatTime(instant: Instant?, raw: String?, twentyFourHour: Boolean, zone: ZoneId): String {
        if (instant == null) return raw?.takeIf { it != "null" }.orEmpty()
        val pattern = if (twentyFourHour) "HH:mm" else "h:mm a"
        return formatter(pattern).format(instant.atZone(zone))
    }

    fun compactOccurrenceLabel(
        occurrence: JSONObject,
        twentyFourHour: Boolean,
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        return compactOccurrenceLabel(
            kind = occurrence.optString("kind"),
            startRaw = occurrence.optionalString("start"),
            endRaw = occurrence.optionalString("end"),
            twentyFourHour = twentyFourHour,
            zone = zone,
        )
    }

    /** Pure value overload keeps the calendar hot path easy to fuzz on the JVM. */
    fun compactOccurrenceLabel(
        kind: String,
        startRaw: String?,
        endRaw: String?,
        twentyFourHour: Boolean,
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        val key = listOf(
            kind,
            startRaw.orEmpty(),
            endRaw.orEmpty(),
            twentyFourHour,
            zone.id,
            Locale.getDefault().toLanguageTag(),
        ).joinToString("\u0000")
        synchronized(compactOccurrenceLabelCache) {
            compactOccurrenceLabelCache[key]?.let { return it }
        }

        val result = when {
            kind == "reminder" -> {
                val start = time(startRaw, twentyFourHour, zone)
                if (start.isNotEmpty()) "At $start" else ""
            }
            kind == "assignment" -> {
                val end = time(endRaw, twentyFourHour, zone)
                if (end.isNotEmpty()) "Due $end" else ""
            }
            else -> {
                val start = compactEventTime(startRaw, twentyFourHour, includePeriod = false, zone = zone)
                val end = compactEventTime(endRaw, twentyFourHour, includePeriod = true, zone = zone)
                when {
                    start.isNotEmpty() && end.isNotEmpty() -> "$start to $end"
                    start.isNotEmpty() -> start
                    end.isNotEmpty() -> "Due $end"
                    else -> ""
                }
            }
        }
        synchronized(compactOccurrenceLabelCache) {
            compactOccurrenceLabelCache[key] = result
        }
        return result
    }

    fun annotationLabel(startRaw: String?, endRaw: String?, twentyFourHour: Boolean): String? {
        val start = time(startRaw, twentyFourHour).takeIf { it.isNotEmpty() }
        val end = time(endRaw, twentyFourHour).takeIf { it.isNotEmpty() }
        return when {
            start != null && end != null -> "$start – $end"
            start != null -> "At $start"
            end != null -> "Due $end"
            else -> null
        }
    }

    fun isCompactEvent(occurrence: JSONObject): Boolean {
        return isCompactEvent(
            kind = occurrence.optString("kind"),
            startRaw = occurrence.optionalString("start"),
            endRaw = occurrence.optionalString("end"),
        )
    }

    fun isCompactEvent(kind: String, startRaw: String?, endRaw: String?): Boolean {
        if (kind != "event") return false
        val start = parseInstant(startRaw) ?: return false
        val end = parseInstant(endRaw) ?: return false
        return end.epochSecond - start.epochSecond <= 30 * 60
    }
}
