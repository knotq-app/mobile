package com.enigmadux.knotq

import java.time.LocalDate
import java.util.Locale

internal object MobileRecurrence {
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

    fun rruleForRepeat(choice: String, date: LocalDate): String? = when (choice) {
        "daily" -> "FREQ=DAILY;INTERVAL=1"
        "weekly" -> "FREQ=WEEKLY;INTERVAL=1;BYDAY=${weekdayCode(date)}"
        "monthly" -> "FREQ=MONTHLY;INTERVAL=1"
        "yearly" -> "FREQ=YEARLY;INTERVAL=1"
        else -> null
    }

    private fun weekdayCode(date: LocalDate): String = when (date.dayOfWeek.value) {
        1 -> "MO"
        2 -> "TU"
        3 -> "WE"
        4 -> "TH"
        5 -> "FR"
        6 -> "SA"
        else -> "SU"
    }
}
