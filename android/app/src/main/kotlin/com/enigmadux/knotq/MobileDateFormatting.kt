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

    fun occurrenceLabel(
        occurrence: JSONObject,
        twentyFourHour: Boolean,
        fallbackToKind: Boolean = true,
        showDay: Boolean = false
    ): String {
        if (showDay) return occurrenceLabelWithDay(occurrence, twentyFourHour)
        val kind = occurrence.optString("kind")
        val start = time(occurrence.optionalString("start"), twentyFourHour)
        val end = time(occurrence.optionalString("end"), twentyFourHour)
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

    /// "Tomorrow", a near-week weekday ("Thu"), or "Jun 18" for dates past a
    /// week out; empty for today. Mirrors iOS `upcomingDatePrefix`.
    fun upcomingDatePrefix(instant: Instant): String {
        val today = LocalDate.now()
        val target = instant.atZone(ZoneId.systemDefault()).toLocalDate()
        if (target == today) return ""
        if (target == today.plusDays(1)) return "Tomorrow"
        if (target.isAfter(today) && target.isBefore(today.plusDays(7))) {
            return target.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.US)
        }
        return "${target.month.getDisplayName(TextStyle.SHORT, Locale.US)} ${target.dayOfMonth}"
    }

    private fun occurrenceLabelWithDay(occurrence: JSONObject, twentyFourHour: Boolean): String {
        val kind = occurrence.optString("kind")
        val startInstant = parseInstant(occurrence.optionalString("start"))
        val endInstant = parseInstant(occurrence.optionalString("end"))
        val start = time(occurrence.optionalString("start"), twentyFourHour)
        val end = time(occurrence.optionalString("end"), twentyFourHour)
        if (kind == "reminder" && startInstant != null && start.isNotEmpty()) {
            val day = upcomingDatePrefix(startInstant)
            return if (day.isEmpty()) "At $start" else "At $day $start"
        }
        if (kind == "assignment" && endInstant != null && end.isNotEmpty()) {
            val day = upcomingDatePrefix(endInstant)
            return if (day.isEmpty()) "Due $end" else "Due $day $end"
        }
        if (startInstant != null && endInstant != null && start.isNotEmpty() && end.isNotEmpty()) {
            val from = upcomingDatePrefix(startInstant)
            val to = upcomingDatePrefix(endInstant)
            val fromText = if (from.isEmpty()) start else "$from $start"
            val toText = if (from == to) end else if (to.isEmpty()) end else "$to $end"
            return "$fromText – $toText"
        }
        if (startInstant != null && start.isNotEmpty()) {
            val day = upcomingDatePrefix(startInstant)
            return if (day.isEmpty()) start else "$day $start"
        }
        if (endInstant != null && end.isNotEmpty()) {
            val day = upcomingDatePrefix(endInstant)
            return if (day.isEmpty()) "Due $end" else "Due $day $end"
        }
        return kind.replaceFirstChar(Char::titlecase)
    }

    fun compactOccurrenceLabel(occurrence: JSONObject, twentyFourHour: Boolean): String {
        val kind = occurrence.optString("kind")
        if (kind == "reminder") {
            val start = time(occurrence.optionalString("start"), twentyFourHour)
            return if (start.isNotEmpty()) "At $start" else ""
        }
        if (kind == "assignment") {
            val end = time(occurrence.optionalString("end"), twentyFourHour)
            return if (end.isNotEmpty()) "Due $end" else ""
        }
        val start = compactEventTime(occurrence.optionalString("start"), twentyFourHour, includePeriod = false)
        val end = compactEventTime(occurrence.optionalString("end"), twentyFourHour, includePeriod = true)
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
            start != null && end != null -> "$start – $end"
            start != null -> "At $start"
            end != null -> "Due $end"
            else -> null
        }
    }

    fun isCompactEvent(occurrence: JSONObject): Boolean {
        if (occurrence.optString("kind") != "event") return false
        val start = parseInstant(occurrence.optionalString("start")) ?: return false
        val end = parseInstant(occurrence.optionalString("end")) ?: return false
        return end.epochSecond - start.epochSecond <= 30 * 60
    }
}
