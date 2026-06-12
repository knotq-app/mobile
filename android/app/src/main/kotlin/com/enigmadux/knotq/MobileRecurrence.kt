package com.enigmadux.knotq

import java.time.LocalDate
import java.util.Locale

internal object MobileRecurrence {
    // Display order matches the iOS weekly picker (Sunday first).
    val weekdayCodes = listOf("SU", "MO", "TU", "WE", "TH", "FR", "SA")
    val weekdayChipLabels = listOf("S", "M", "T", "W", "T", "F", "S")

    fun repeatChoiceFromRrule(rrule: String?): String {
        val upper = rrule?.uppercase(Locale.US) ?: return "none"
        return when {
            upper.contains("FREQ=DAILY") -> "daily"
            upper.contains("FREQ=WEEKLY") -> "weekly"
            upper.contains("FREQ=MONTHLY") -> "monthly"
            upper.contains("FREQ=YEARLY") -> "yearly"
            else -> "none"
        }
    }

    /// iOS `RepeatWeekdayChoice.selected(from:fallbackDate:)`: the BYDAY codes
    /// of the rule, defaulting to the anchor date's weekday.
    fun selectedWeekdays(rrule: String?, fallback: LocalDate): MutableSet<String> {
        val default = mutableSetOf(weekdayCode(fallback))
        val upper = rrule?.uppercase(Locale.US)?.replace("RRULE:", "")?.trim()
        if (upper.isNullOrEmpty()) return default
        val byday = upper.split(";").firstOrNull { it.startsWith("BYDAY=") } ?: return default
        val parsed = byday.removePrefix("BYDAY=")
            .split(",")
            .mapNotNull { part -> part.trim().takeLast(2).takeIf { it in weekdayCodes } }
        return if (parsed.isEmpty()) default else parsed.toMutableSet()
    }

    fun rruleForRepeat(choice: String, date: LocalDate, weekdays: Set<String> = emptySet()): String? = when (choice) {
        "daily" -> "FREQ=DAILY;INTERVAL=1"
        "weekly" -> {
            // Serialized Monday-first like iOS `orderedCodes`.
            val codes = listOf("MO", "TU", "WE", "TH", "FR", "SA", "SU")
                .filter { weekdays.contains(it) }
                .ifEmpty { listOf(weekdayCode(date)) }
            "FREQ=WEEKLY;INTERVAL=1;BYDAY=${codes.joinToString(",")}"
        }
        "monthly" -> "FREQ=MONTHLY;INTERVAL=1"
        "yearly" -> "FREQ=YEARLY;INTERVAL=1"
        else -> null
    }

    fun weekdayCode(date: LocalDate): String = when (date.dayOfWeek.value) {
        1 -> "MO"
        2 -> "TU"
        3 -> "WE"
        4 -> "TH"
        5 -> "FR"
        6 -> "SA"
        else -> "SU"
    }
}
