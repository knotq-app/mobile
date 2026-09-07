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

    // Values are L10n catalog keys (not raw text) since this list is built at
    // object-init time, before a Context is available to resolve strings.
    private val snoozeActions = listOf(
        ACTION_SNOOZE_1_MINUTE to "mobile.notifications.snooze_1m",
        ACTION_SNOOZE_5_MINUTES to "mobile.notifications.snooze_5m",
        ACTION_SNOOZE_10_MINUTES to "mobile.notifications.snooze_10m",
        ACTION_SNOOZE_15_MINUTES to "mobile.notifications.snooze_15m",
        ACTION_SNOOZE_30_MINUTES to "mobile.notifications.snooze_30m",
        ACTION_SNOOZE_1_HOUR to "mobile.notifications.snooze_1h",
        ACTION_SNOOZE_2_HOURS to "mobile.notifications.snooze_2h",
        ACTION_SNOOZE_1_DAY to "mobile.notifications.snooze_1d",
        ACTION_SNOOZE_1_WEEK to "mobile.notifications.snooze_1w"
    )

    private const val CHANNEL_ID = "knotq-reminders"
    private const val PREFS = "knotq.notifications"
    private const val PREF_SCHEDULED_IDS = "scheduled_ids"
    private const val REQUEST_POST_NOTIFICATIONS = 7201
    private const val MAX_PENDING_NOTIFICATIONS = 64

    private const val EXTRA_NOTIFICATION_ID = "notification_id"
    private const val EXTRA_FIRE_AT = "fire_at"
    private const val EXTRA_EXPIRES_AT = "expires_at"
    private const val EXTRA_END_AT = "end_at"
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

    /// Run [block] against the app's core, reusing the activity's live bridge when
    /// one exists. Opening a second `MobileCore` alongside it gives two instances
    /// their own in-memory workspace over the same files, so whichever saves last
    /// silently reverts the other's edit — the pattern BackgroundSyncWorker
    /// already follows. Only a bridge we opened ourselves is closed.
    private fun <T> withCore(context: Context, block: (RustBridge) -> T): T {
        val shared = MainActivity.sharedBridge
        val bridge = shared ?: RustBridge(context.applicationContext)
        return try {
            block(bridge)
        } finally {
            if (shared == null) bridge.close()
        }
    }

    fun refreshFromCore(context: Context) {
        withCore(context) { bridge ->
            val requests = bridge.requestArray(JSONObject().put("type", "pending_notifications"))
            reschedule(context, requests)
            clearStale(
                context,
                bridge.requestArray(JSONObject().put("type", "delivered_notifications_to_clear"))
            )
        }
    }

    // Tear down delivered banners (and any matching pending alarm) the core
    // flagged as stale — an event past its end time, or a completed occurrence.
    // reschedule() only re-aims future alarms, so this is what removes a banner
    // that already fired once it no longer applies. Mirrors iOS clearDelivered.
    fun clearStale(context: Context, ids: JSONArray) {
        if (ids.length() == 0) return
        val appContext = context.applicationContext
        val cleared = HashSet<String>()
        for (index in 0 until ids.length()) {
            val id = ids.optString(index).takeIf { it.isNotBlank() } ?: continue
            cancelAlarm(appContext, id)
            cleared.add(id)
        }
        if (cleared.isNotEmpty()) {
            saveScheduledIds(appContext, scheduledIds(appContext) - cleared)
        }
    }

    fun reschedule(context: Context, requests: JSONArray) {
        val appContext = context.applicationContext
        ensureChannel(appContext)

        val stored = scheduledIds(appContext)

        if (!hasPermission(appContext)) {
            // We no longer have a way to show these notifications, so leave no
            // stale wake-up alarms behind. This also keeps a later permission
            // grant from delivering a schedule that was superseded while
            // notifications were disabled.
            stored.forEach { cancelAlarm(appContext, it) }
            saveScheduledIds(appContext, emptySet())
            return
        }

        val now = Instant.now()
        val desired = LinkedHashSet<String>()
        val requestsToSchedule = ArrayList<Pair<JSONObject, Instant>>()
        for (index in 0 until requests.length()) {
            if (desired.size >= MAX_PENDING_NOTIFICATIONS) break
            val request = requests.optJSONObject(index) ?: continue
            val id = request.optString("id")
            val fireAt = request.optInstant(EXTRA_FIRE_AT) ?: continue
            if (id.isBlank() || !fireAt.isAfter(now)) continue
            desired.add(id)
            requestsToSchedule.add(request to fireAt)
        }

        // Add/update desired alarms before tearing down anything. Reusing the
        // same PendingIntent replaces that alarm atomically; cancelling every
        // id first left a kill-window with no reminders armed and also called
        // `NotificationManager.cancel` for delivered banners that were still
        // relevant. Only notifications absent from the desired set are stale.
        requestsToSchedule.forEach { (request, fireAt) ->
            scheduleOne(appContext, request, fireAt)
        }
        (stored - desired).forEach { cancelAlarm(appContext, it) }
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

        val now = Instant.now()
        val endAt = intent.getStringExtra(EXTRA_END_AT)?.takeIf { it.isNotBlank() }
            ?.let { runCatching { Instant.parse(it) }.getOrNull() }
        val kind = intent.getStringExtra(EXTRA_KIND).orEmpty()
        val fireAt = intent.getStringExtra(EXTRA_FIRE_AT)
            ?.let { runCatching { Instant.parse(it) }.getOrNull() }
        val title = intent.getStringExtra(EXTRA_TITLE)?.ifBlank { "KnotQ" } ?: "KnotQ"
        val fallbackBody = L10n.t(appContext, "mobile.notifications.fallback_body")
        val body = intent.getStringExtra(EXTRA_BODY)?.ifBlank { fallbackBody } ?: fallbackBody
        val manager = appContext.getSystemService(NotificationManager::class.java)
        val builder = Notification.Builder(appContext, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setWhen(
                if (kind == "event" && endAt != null && endAt.isAfter(now)) {
                    endAt.toEpochMilli()
                } else {
                    fireAt?.toEpochMilli() ?: System.currentTimeMillis()
                }
            )
            .setShowWhen(true)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setContentIntent(openAppIntent(appContext, id))
        if (kind == "event" && endAt != null && endAt.isAfter(now)) {
            builder
                .setUsesChronometer(true)
                .setChronometerCountDown(true)
                // Past the event's end there is no point showing it. Android will
                // dismiss the banner itself at that moment — no app wake needed,
                // unlike iOS which has no per-notification TTL and must sweep on
                // the next foreground/background run. `end_at` is always set for
                // an event (the core synthesizes one when the item has no
                // explicit end).
                .setTimeoutAfter(endAt.toEpochMilli() - now.toEpochMilli())
        }
        snoozeActions.forEach { (action, titleKey) ->
            builder.addAction(notificationAction(appContext, id, action, L10n.t(appContext, titleKey), intent))
        }
        val notification = builder
            .addAction(
                notificationAction(
                    appContext,
                    id,
                    ACTION_MARK_DONE,
                    L10n.t(appContext, "mobile.notifications.mark_done"),
                    intent
                )
            )
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
        withCore(appContext) { it.request(body) }
        refreshFromCore(appContext)
        // The receiver mutated the core behind a live (but stopped) activity's
        // back. Without this the app still shows the item as pending when the
        // user returns to it — stale until a full restart.
        MainActivity.notifyExternalStateChanged()
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
            putExtra(EXTRA_END_AT, request.optString("end_at"))
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
            L10n.t(context, "mobile.notifications.channel_name"),
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = L10n.t(context, "mobile.notifications.channel_description")
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
