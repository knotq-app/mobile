package com.enigmadux.knotq

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.graphics.drawable.Icon
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

internal object MobileNotificationScheduler {
    const val ACTION_DELIVER = "com.enigmadux.knotq.notifications.DELIVER"
    const val ACTION_MARK_DONE = "knotq.mark_done"
    const val ACTION_SNOOZE_1_MINUTE = "knotq.snooze.1m"
    const val ACTION_SNOOZE_5_MINUTES = "knotq.snooze.5m"
    const val ACTION_SNOOZE_10_MINUTES = "knotq.snooze.10m"
    const val ACTION_SNOOZE_15_MINUTES = "knotq.snooze.15m"
    const val ACTION_SNOOZE_30_MINUTES = "knotq.snooze.30m"
    const val ACTION_SNOOZE_1_HOUR = "knotq.snooze.1h"
    const val ACTION_SNOOZE_2_HOURS = "knotq.snooze.2h"
    const val ACTION_SNOOZE_1_DAY = "knotq.snooze.1d"
    const val ACTION_SNOOZE_1_WEEK = "knotq.snooze.1w"

    private val snoozeActions = listOf(
        ACTION_SNOOZE_1_MINUTE to "Snooze 1m",
        ACTION_SNOOZE_5_MINUTES to "Snooze 5m",
        ACTION_SNOOZE_10_MINUTES to "Snooze 10m",
        ACTION_SNOOZE_15_MINUTES to "Snooze 15m",
        ACTION_SNOOZE_30_MINUTES to "Snooze 30m",
        ACTION_SNOOZE_1_HOUR to "Snooze 1h",
        ACTION_SNOOZE_2_HOURS to "Snooze 2h",
        ACTION_SNOOZE_1_DAY to "Snooze 1d",
        ACTION_SNOOZE_1_WEEK to "Snooze 1w"
    )

    private const val CHANNEL_ID = "knotq-reminders"
    private const val PREFS = "knotq.notifications"
    private const val PREF_SCHEDULED_IDS = "scheduled_ids"
    private const val REQUEST_POST_NOTIFICATIONS = 7201
    private const val MAX_PENDING_NOTIFICATIONS = 64

    private const val EXTRA_NOTIFICATION_ID = "notification_id"
    private const val EXTRA_FIRE_AT = "fire_at"
    private const val EXTRA_EXPIRES_AT = "expires_at"
    private const val EXTRA_TITLE = "title"
    private const val EXTRA_BODY = "body"
    private const val EXTRA_KIND = "kind"
    private const val EXTRA_SCHEME_ID = "scheme_id"
    private const val EXTRA_ITEM_ID = "item_id"
    private const val EXTRA_OCCURRENCE_JSON = "occurrence_json"
    private const val EXTRA_TRIGGER_AT = "trigger_at"

    fun requestPermission(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || hasPermission(activity)) {
            return
        }
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_POST_NOTIFICATIONS
        )
    }

    fun isNotificationPermissionRequest(requestCode: Int): Boolean =
        requestCode == REQUEST_POST_NOTIFICATIONS

    fun isNotificationAction(action: String?): Boolean =
        action == ACTION_MARK_DONE || snoozeActions.any { it.first == action }

    fun refreshFromCore(context: Context) {
        val bridge = RustBridge(context.applicationContext)
        try {
            val requests = bridge.requestArray(JSONObject().put("type", "pending_notifications"))
            reschedule(context, requests)
        } finally {
            bridge.close()
        }
    }

    fun reschedule(context: Context, requests: JSONArray) {
        val appContext = context.applicationContext
        ensureChannel(appContext)

        val stored = scheduledIds(appContext)
        stored.forEach { cancelAlarm(appContext, it) }

        if (!hasPermission(appContext)) {
            saveScheduledIds(appContext, emptySet())
            return
        }

        val now = Instant.now()
        val desired = LinkedHashSet<String>()
        for (index in 0 until requests.length()) {
            if (desired.size >= MAX_PENDING_NOTIFICATIONS) break
            val request = requests.optJSONObject(index) ?: continue
            val id = request.optString("id")
            val fireAt = request.optInstant(EXTRA_FIRE_AT) ?: continue
            if (id.isBlank() || !fireAt.isAfter(now)) continue
            scheduleOne(appContext, request, fireAt)
            desired.add(id)
        }
        saveScheduledIds(appContext, desired)
    }

    fun deliver(context: Context, intent: Intent) {
        val appContext = context.applicationContext
        if (!hasPermission(appContext)) return
        val id = intent.getStringExtra(EXTRA_NOTIFICATION_ID) ?: return
        val expiresAt = intent.getStringExtra(EXTRA_EXPIRES_AT)?.takeIf { it.isNotBlank() }
            ?.let { runCatching { Instant.parse(it) }.getOrNull() }
        if (expiresAt != null && !expiresAt.isAfter(Instant.now())) {
            return
        }
        ensureChannel(appContext)

        val title = intent.getStringExtra(EXTRA_TITLE)?.ifBlank { "KnotQ" } ?: "KnotQ"
        val body = intent.getStringExtra(EXTRA_BODY)?.ifBlank { "Scheduled item" } ?: "Scheduled item"
        val manager = appContext.getSystemService(NotificationManager::class.java)
        val builder = Notification.Builder(appContext, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setWhen(intent.getStringExtra(EXTRA_FIRE_AT)?.let { Instant.parse(it).toEpochMilli() }
                ?: System.currentTimeMillis())
            .setShowWhen(true)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setContentIntent(openAppIntent(appContext, id))
        snoozeActions.forEach { (action, title) ->
            builder.addAction(notificationAction(appContext, id, action, title, intent))
        }
        val notification = builder
            .addAction(notificationAction(appContext, id, ACTION_MARK_DONE, "Mark done", intent))
            .build()
        manager.notify(id, 0, notification)
    }

    fun handleAction(context: Context, intent: Intent) {
        val appContext = context.applicationContext
        val actionId = intent.action ?: return
        val id = intent.getStringExtra(EXTRA_NOTIFICATION_ID) ?: return
        appContext.getSystemService(NotificationManager::class.java).cancel(id, 0)

        val body = JSONObject()
            .put("type", "apply_notification_action")
            .put("action_id", actionId)
            .put("scheme_id", intent.getStringExtra(EXTRA_SCHEME_ID).orEmpty())
            .put("item_id", intent.getStringExtra(EXTRA_ITEM_ID).orEmpty())
            .put("occurrence_json", intent.getStringExtra(EXTRA_OCCURRENCE_JSON).orEmpty())
            .put("trigger_at", intent.getStringExtra(EXTRA_TRIGGER_AT).orEmpty())
        val bridge = RustBridge(appContext)
        try {
            bridge.request(body)
        } finally {
            bridge.close()
        }
        refreshFromCore(appContext)
    }

    private fun scheduleOne(context: Context, request: JSONObject, fireAt: Instant) {
        val alarm = context.getSystemService(AlarmManager::class.java)
        alarm.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            fireAt.toEpochMilli(),
            deliveryPendingIntent(context, request)
        )
    }

    private fun cancelAlarm(context: Context, id: String) {
        val alarm = context.getSystemService(AlarmManager::class.java)
        alarm.cancel(deliveryPendingIntent(context, id))
        context.getSystemService(NotificationManager::class.java).cancel(id, 0)
    }

    private fun deliveryPendingIntent(context: Context, request: JSONObject): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            requestCode(request.optString("id"), ACTION_DELIVER),
            deliveryIntent(context, request),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    private fun deliveryPendingIntent(context: Context, id: String): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            requestCode(id, ACTION_DELIVER),
            deliveryIntent(context, id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    private fun deliveryIntent(context: Context, request: JSONObject): Intent =
        deliveryIntent(context, request.optString("id")).apply {
            putExtra(EXTRA_NOTIFICATION_ID, request.optString("id"))
            putExtra(EXTRA_FIRE_AT, request.optString("fire_at"))
            putExtra(EXTRA_EXPIRES_AT, request.optString("expires_at"))
            putExtra(EXTRA_TITLE, request.optString("title"))
            putExtra(EXTRA_BODY, request.optString("body"))
            putExtra(EXTRA_KIND, request.optString("kind"))
            putExtra(EXTRA_SCHEME_ID, request.optString("scheme_id"))
            putExtra(EXTRA_ITEM_ID, request.optString("item_id"))
            putExtra(EXTRA_OCCURRENCE_JSON, request.optString("occurrence_json"))
            putExtra(EXTRA_TRIGGER_AT, request.optString("trigger_at"))
        }

    private fun deliveryIntent(context: Context, id: String): Intent =
        Intent(context, NotificationReceiver::class.java).apply {
            action = ACTION_DELIVER
            data = notificationUri(id, ACTION_DELIVER)
        }

    private fun notificationAction(
        context: Context,
        id: String,
        action: String,
        title: String,
        source: Intent
    ): Notification.Action {
        val intent = Intent(context, NotificationReceiver::class.java).apply {
            this.action = action
            data = notificationUri(id, action)
            putExtras(source)
        }
        val pending = PendingIntent.getBroadcast(
            context,
            requestCode(id, action),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Action.Builder(
            Icon.createWithResource(context, R.mipmap.ic_launcher),
            title,
            pending
        ).build()
    }

    private fun openAppIntent(context: Context, id: String): PendingIntent =
        PendingIntent.getActivity(
            context,
            requestCode(id, "open"),
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                data = notificationUri(id, "open")
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    private fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "KnotQ reminders",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Calendar reminders and assignments from KnotQ"
            enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }

    private fun hasPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun scheduledIds(context: Context): Set<String> =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(PREF_SCHEDULED_IDS, emptySet())
            ?.toSet()
            ?: emptySet()

    private fun saveScheduledIds(context: Context, ids: Set<String>) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(PREF_SCHEDULED_IDS, ids)
            .apply()
    }

    private fun requestCode(id: String, action: String): Int = "$id:$action".hashCode()

    private fun notificationUri(id: String, action: String): Uri =
        Uri.parse("knotq://notification/${Uri.encode(id)}/${Uri.encode(action)}")

    private fun JSONObject.optInstant(key: String): Instant? =
        optString(key).takeIf { it.isNotBlank() }?.let { raw ->
            runCatching { Instant.parse(raw) }.getOrNull()
        }
}
