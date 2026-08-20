package com.enigmadux.knotq

import android.content.Context

internal data class NotificationLeadTimeOption(
    val labelKey: String,
    val offsetSecs: Int,
    val customLabel: String? = null,
) {
    fun label(context: Context): String = customLabel ?: L10n.t(context, labelKey)
}

internal const val DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS = 10 * 60
internal const val DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS = 2 * 60 * 60

internal val eventDefaultNotificationOptions: List<NotificationLeadTimeOption> = listOf(
    NotificationLeadTimeOption("settings.notifications.offset_at_start", 0),
    NotificationLeadTimeOption("settings.notifications.offset_5_min", 5 * 60),
    NotificationLeadTimeOption("settings.notifications.offset_10_min", DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS),
    NotificationLeadTimeOption("settings.notifications.offset_15_min", 15 * 60),
    NotificationLeadTimeOption("settings.notifications.offset_30_min", 30 * 60),
    NotificationLeadTimeOption("settings.notifications.offset_1_hr", 60 * 60),
)

internal val assignmentDefaultNotificationOptions: List<NotificationLeadTimeOption> = listOf(
    NotificationLeadTimeOption("settings.notifications.offset_at_due", 0),
    NotificationLeadTimeOption("settings.notifications.offset_1_hr", 60 * 60),
    NotificationLeadTimeOption("settings.notifications.offset_2_hr", DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS),
    NotificationLeadTimeOption("settings.notifications.offset_6_hr", 6 * 60 * 60),
    NotificationLeadTimeOption("settings.notifications.offset_1_day", 24 * 60 * 60),
    NotificationLeadTimeOption("settings.notifications.offset_2_days", 2 * 24 * 60 * 60),
)

private val occurrenceNotificationOptions: List<NotificationLeadTimeOption> = listOf(
    NotificationLeadTimeOption("event.notification.at_time", 0),
    NotificationLeadTimeOption("settings.notifications.offset_5_min", 5 * 60),
    NotificationLeadTimeOption("settings.notifications.offset_10_min", DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS),
    NotificationLeadTimeOption("settings.notifications.offset_30_min", 30 * 60),
    NotificationLeadTimeOption("settings.notifications.offset_1_hr", 60 * 60),
    NotificationLeadTimeOption("settings.notifications.offset_1_day", 24 * 60 * 60),
)

internal fun notificationLeadTimeLabel(context: Context, offsetSecs: Int, eventDefault: Boolean? = null): String {
    if (offsetSecs == 0) {
        return when (eventDefault) {
            true -> L10n.t(context, "settings.notifications.offset_at_start")
            false -> L10n.t(context, "settings.notifications.offset_at_due")
            null -> L10n.t(context, "event.notification.at_time")
        }
    }
    (
        occurrenceNotificationOptions +
            eventDefaultNotificationOptions +
            assignmentDefaultNotificationOptions
        ).firstOrNull { it.offsetSecs == offsetSecs }?.let { return it.label(context) }
    // Desktop `format_lead_time` fallback: decomposed duration + before/after.
    val suffix = L10n.t(context, if (offsetSecs > 0) "event.notification.before" else "event.notification.after")
    return "${formatLeadDuration(kotlin.math.abs(offsetSecs))} $suffix"
}

private fun formatLeadDuration(seconds: Int): String {
    val days = seconds / 86_400
    if (days > 0 && seconds % 86_400 == 0) return pluralUnit(days, "day")
    val hours = seconds / 3_600
    if (hours > 0 && seconds % 3_600 == 0) return pluralUnit(hours, "hour")
    val minutes = seconds / 60
    if (minutes > 0) return pluralUnit(minutes, "minute")
    return pluralUnit(seconds, "second")
}

private fun pluralUnit(count: Int, unit: String): String =
    if (count == 1) "1 $unit" else "$count ${unit}s"

internal fun occurrenceNotificationOptionsIncluding(context: Context, offsetSecs: Int): List<NotificationLeadTimeOption> {
    if (occurrenceNotificationOptions.any { it.offsetSecs == offsetSecs }) {
        return occurrenceNotificationOptions
    }
    return (occurrenceNotificationOptions + NotificationLeadTimeOption(
        "event.notification.at_time",
        offsetSecs,
        notificationLeadTimeLabel(context, offsetSecs),
    ))
        .sortedBy { it.offsetSecs }
}
