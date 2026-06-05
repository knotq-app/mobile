package com.enigmadux.knotq

internal data class NotificationLeadTimeOption(
    val label: String,
    val offsetSecs: Int,
)

internal val eventDefaultNotificationOptions: List<NotificationLeadTimeOption> = listOf(
    NotificationLeadTimeOption("At start", 0),
    NotificationLeadTimeOption("5 minutes before", 5 * 60),
    NotificationLeadTimeOption("10 minutes before", 10 * 60),
    NotificationLeadTimeOption("15 minutes before", 15 * 60),
    NotificationLeadTimeOption("30 minutes before", 30 * 60),
    NotificationLeadTimeOption("1 hour before", 60 * 60),
)

internal val assignmentDefaultNotificationOptions: List<NotificationLeadTimeOption> = listOf(
    NotificationLeadTimeOption("At due time", 0),
    NotificationLeadTimeOption("1 hour before", 60 * 60),
    NotificationLeadTimeOption("2 hours before", 2 * 60 * 60),
    NotificationLeadTimeOption("6 hours before", 6 * 60 * 60),
    NotificationLeadTimeOption("1 day before", 24 * 60 * 60),
    NotificationLeadTimeOption("2 days before", 2 * 24 * 60 * 60),
)

private val occurrenceNotificationOptions: List<NotificationLeadTimeOption> = listOf(
    NotificationLeadTimeOption("At time", 0),
    NotificationLeadTimeOption("5 minutes before", 5 * 60),
    NotificationLeadTimeOption("10 minutes before", 10 * 60),
    NotificationLeadTimeOption("30 minutes before", 30 * 60),
    NotificationLeadTimeOption("1 hour before", 60 * 60),
    NotificationLeadTimeOption("1 day before", 24 * 60 * 60),
)

internal fun notificationLeadTimeLabel(offsetSecs: Int, eventDefault: Boolean? = null): String {
    if (offsetSecs == 0) {
        return when (eventDefault) {
            true -> "At start"
            false -> "At due time"
            null -> "At time"
        }
    }
    return (
        occurrenceNotificationOptions +
            eventDefaultNotificationOptions +
            assignmentDefaultNotificationOptions
        ).firstOrNull { it.offsetSecs == offsetSecs }?.label
        ?: "${offsetSecs / 60} minutes before"
}

internal fun occurrenceNotificationOptionsIncluding(offsetSecs: Int): List<NotificationLeadTimeOption> {
    if (occurrenceNotificationOptions.any { it.offsetSecs == offsetSecs }) {
        return occurrenceNotificationOptions
    }
    return (occurrenceNotificationOptions + NotificationLeadTimeOption(notificationLeadTimeLabel(offsetSecs), offsetSecs))
        .sortedBy { it.offsetSecs }
}
