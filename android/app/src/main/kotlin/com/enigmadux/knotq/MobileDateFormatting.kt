package com.enigmadux.knotq

import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale

internal object MobileDateFormatting {
    fun parseInstant(raw: String?): Instant? {
        if (raw.isNullOrEmpty() || raw == "null") return null
        return runCatching { Instant.parse(raw) }.getOrNull()
    }

    fun localDateTime(raw: String?): ZonedDateTime? =
        parseInstant(raw)?.atZone(ZoneId.systemDefault())

    fun iso(date: LocalDate, hour: Int, minute: Int): String =
        ZonedDateTime.of(date, LocalTime.of(hour, minute), ZoneId.systemDefault())
            .withZoneSameInstant(ZoneOffset.UTC)
            .format(DateTimeFormatter.ISO_INSTANT)

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

    fun time(raw: String?, twentyFourHour: Boolean): String {
        val instant = parseInstant(raw) ?: return raw?.takeIf { it != "null" }.orEmpty()
        val pattern = if (twentyFourHour) "HH:mm" else "h:mm a"
        return DateTimeFormatter.ofPattern(pattern).format(instant.atZone(ZoneId.systemDefault()))
    }

    fun compactEventTime(raw: String?, twentyFourHour: Boolean, includePeriod: Boolean): String {
        val instant = parseInstant(raw) ?: return raw?.takeIf { it != "null" }.orEmpty()
        val pattern = if (twentyFourHour) "HH:mm" else if (includePeriod) "h:mm a" else "h:mm"
        return DateTimeFormatter.ofPattern(pattern).format(instant.atZone(ZoneId.systemDefault()))
    }

    fun occurrenceLabel(occurrence: JSONObject, twentyFourHour: Boolean, fallbackToKind: Boolean = true): String {
        val kind = occurrence.optString("kind")
        val start = time(occurrence.optionalStringForDate("start"), twentyFourHour)
        val end = time(occurrence.optionalStringForDate("end"), twentyFourHour)
        if (kind == "reminder" && start.isNotEmpty()) return "At $start"
        if (kind == "assignment" && end.isNotEmpty()) return "Due $end"
        return when {
            start.isNotEmpty() && end.isNotEmpty() -> "$start - $end"
            start.isNotEmpty() -> start
            end.isNotEmpty() -> "Due $end"
            fallbackToKind -> kind.replaceFirstChar(Char::titlecase)
            else -> ""
        }
    }

    fun compactOccurrenceLabel(occurrence: JSONObject, twentyFourHour: Boolean): String {
        val kind = occurrence.optString("kind")
        if (kind == "reminder") {
            val start = time(occurrence.optionalStringForDate("start"), twentyFourHour)
            return if (start.isNotEmpty()) "At $start" else ""
        }
        if (kind == "assignment") {
            val end = time(occurrence.optionalStringForDate("end"), twentyFourHour)
            return if (end.isNotEmpty()) "Due $end" else ""
        }
        val start = compactEventTime(occurrence.optionalStringForDate("start"), twentyFourHour, includePeriod = false)
        val end = compactEventTime(occurrence.optionalStringForDate("end"), twentyFourHour, includePeriod = true)
        return when {
            start.isNotEmpty() && end.isNotEmpty() -> "$start to $end"
            start.isNotEmpty() -> start
            end.isNotEmpty() -> "Due $end"
            else -> ""
        }
    }

    fun annotationLabel(startRaw: String?, endRaw: String?, twentyFourHour: Boolean): String? {
        val start = time(startRaw, twentyFourHour).takeIf { it.isNotEmpty() }
        val end = time(endRaw, twentyFourHour).takeIf { it.isNotEmpty() }
        return when {
            start != null && end != null -> "$start → $end"
            start != null -> "At $start"
            end != null -> "Due $end"
            else -> null
        }
    }

    fun isCompactEvent(occurrence: JSONObject): Boolean {
        if (occurrence.optString("kind") != "event") return false
        val start = parseInstant(occurrence.optionalStringForDate("start")) ?: return false
        val end = parseInstant(occurrence.optionalStringForDate("end")) ?: return false
        return end.epochSecond - start.epochSecond <= 30 * 60
    }
}

private fun JSONObject.optionalStringForDate(name: String): String? =
    if (isNull(name)) null else optString(name).takeIf { it.isNotEmpty() && it != "null" }
