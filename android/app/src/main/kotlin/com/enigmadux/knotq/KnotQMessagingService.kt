package com.enigmadux.knotq

import android.content.Context
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject

/// Receives Firebase Cloud Messaging pushes (the Android counterpart of iOS's
/// BackgroundSyncCoordinator). The backend sends a silent, data-only message
/// whenever a peer device changes the notification schedule; we react by pulling
/// the change and re-arming local alarms so reminders fire on this device too.
///
/// Nothing here opens its own core: registering the FCM token and syncing both
/// happen on a single `RustBridge` (two open cores clobber each other's in-memory
/// workspace), so we route through the shared activity bridge or the background
/// sync worker rather than touching a core directly.
class KnotQMessagingService : FirebaseMessagingService() {

    /// Fired when FCM issues or rotates this device's token. Persist it and, if
    /// the app is alive, hand it to the live core immediately; otherwise the
    /// queued sync (and `MainActivity` on next launch) picks it up from prefs.
    override fun onNewToken(token: String) {
        PushRegistration.store(applicationContext, token)
        MainActivity.sharedBridge?.let { PushRegistration.apply(it, token) }
        enqueueOneTimeSync(applicationContext)
    }

    /// A peer device changed the notification schedule. Pull + reschedule via the
    /// background sync worker (which no-ops while foregrounded — the 30s poll owns
    /// syncing there). The message is data-only so this fires even when the app is
    /// backgrounded.
    override fun onMessageReceived(message: RemoteMessage) {
        if (message.data["type"] != PushRegistration.SCHEDULE_CHANGED) return
        enqueueOneTimeSync(applicationContext)
    }

    private fun enqueueOneTimeSync(context: Context) {
        runCatching {
            val request = OneTimeWorkRequest.Builder(BackgroundSyncWorker::class.java).build()
            // KEEP coalesces a burst of pushes (one per peer edit) into a single
            // sync instead of stacking redundant runs.
            WorkManager.getInstance(context)
                .enqueueUniqueWork("knotq-push-sync", ExistingWorkPolicy.KEEP, request)
        }
    }
}

/// Shared plumbing for the FCM push token. The token lives in the core only in
/// memory (per `RustBridge`), and the core registers it with the backend during
/// `sync_once`; persisting it here lets every sync path (foreground poll, the
/// background worker, a fresh launch) re-apply the same token before syncing.
internal object PushRegistration {
    const val SCHEDULE_CHANGED = "notification_schedule_changed"

    private const val PREFS = "knotq"
    private const val TOKEN_KEY = "fcm_push_token"

    // `environment` is an APNs sandbox/production distinction with no meaning for
    // FCM; "production" matches the core's default and is ignored on the Android
    // send path (the backend keys off push_channel == "fcm").
    private const val ENVIRONMENT = "production"

    fun store(context: Context, token: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(TOKEN_KEY, token)
            .apply()
    }

    fun stored(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(TOKEN_KEY, null)
            ?.takeIf { it.isNotBlank() }

    /// Hand the token to a core instance so its next `sync_once` registers this
    /// device. Idempotent: the core dedupes by token, so re-applying is cheap.
    fun apply(bridge: RustBridge, token: String) {
        runCatching {
            bridge.request(
                JSONObject()
                    .put("type", "set_push_registration")
                    .put("token", token)
                    .put("environment", ENVIRONMENT)
            )
        }
    }
}
