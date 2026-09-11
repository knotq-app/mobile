package com.enigmadux.knotq

internal data class NotificationLeadTimeOption(
    val label: String,
    val offsetSecs: Int,
)

internal const val DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS = 10 * 60
internal const val DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS = 2 * 60 * 60

internal val eventDefaultNotificationOptions: List<NotificationLeadTimeOption> = listOf(
    NotificationLeadTimeOption("At start", 0),
    NotificationLeadTimeOption("5 minutes before", 5 * 60),
    NotificationLeadTimeOption("10 minutes before", DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS),
    NotificationLeadTimeOption("15 minutes before", 15 * 60),
    NotificationLeadTimeOption("30 minutes before", 30 * 60),
    NotificationLeadTimeOption("1 hour before", 60 * 60),
)

internal val assignmentDefaultNotificationOptions: List<NotificationLeadTimeOption> = listOf(
    NotificationLeadTimeOption("At due time", 0),
    NotificationLeadTimeOption("1 hour before", 60 * 60),
    NotificationLeadTimeOption("2 hours before", DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS),
    NotificationLeadTimeOption("6 hours before", 6 * 60 * 60),
    NotificationLeadTimeOption("1 day before", 24 * 60 * 60),
    NotificationLeadTimeOption("2 days before", 2 * 24 * 60 * 60),
)

private val occurrenceNotificationOptions: List<NotificationLeadTimeOption> = listOf(
    NotificationLeadTimeOption("At time", 0),
    NotificationLeadTimeOption("5 minutes before", 5 * 60),
    NotificationLeadTimeOption("10 minutes before", DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS),
    NotificationLeadTimeOption("30 minutes before", 30 * 60),
    NotificationLeadTimeOption("1 hour before", 60 * 60),
    NotificationLeadTimeOption("1 day before", 24 * 60 * 60),
)

// These labels are used while occurrence rows are rebuilt. Keep the lookup
// allocation-free on the render path, and preserve the first label when the
// event/assignment lists intentionally share an offset.
private val notificationLabelByOffset: Map<Int, String> = linkedMapOf<Int, String>().apply {
    (occurrenceNotificationOptions + eventDefaultNotificationOptions + assignmentDefaultNotificationOptions)
        .forEach { option ->
            if (!containsKey(option.offsetSecs)) this[option.offsetSecs] = option.label
        }
}

internal fun notificationLeadTimeLabel(offsetSecs: Int, eventDefault: Boolean? = null): String {
    if (offsetSecs == 0) {
        return when (eventDefault) {
            true -> "At start"
            false -> "At due time"
            null -> "At time"
        }
    }
    notificationLabelByOffset[offsetSecs]?.let { return it }
    // Desktop `format_lead_time` fallback: decomposed duration + before/after.
    val suffix = if (offsetSecs > 0) "before" else "after"
    return "${formatLeadDuration(kotlin.math.abs(offsetSecs.toLong()))} $suffix"
}

private fun formatLeadDuration(seconds: Long): String {
    val days = seconds / 86_400L
    if (days > 0 && seconds % 86_400L == 0L) return pluralUnit(days, "day")
    val hours = seconds / 3_600L
    if (hours > 0 && seconds % 3_600L == 0L) return pluralUnit(hours, "hour")
    val minutes = seconds / 60L
    if (minutes > 0) return pluralUnit(minutes, "minute")
    return pluralUnit(seconds, "second")
}

private fun pluralUnit(count: Long, unit: String): String =
    if (count == 1L) "1 $unit" else "$count ${unit}s"

internal fun occurrenceNotificationOptionsIncluding(offsetSecs: Int): List<NotificationLeadTimeOption> {
    if (notificationLabelByOffset.containsKey(offsetSecs)) {
        return occurrenceNotificationOptions
    }
    return (occurrenceNotificationOptions + NotificationLeadTimeOption(notificationLeadTimeLabel(offsetSecs), offsetSecs))
        .sortedBy { it.offsetSecs }
}
