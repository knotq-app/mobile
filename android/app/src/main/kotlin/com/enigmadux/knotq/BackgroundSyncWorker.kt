package com.enigmadux.knotq

import android.content.Context
import android.content.SharedPreferences
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.enigmadux.knotq.ffi.MobileException
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant

/// Periodic background sync, mirroring the iOS BGAppRefreshTask: while signed
/// in, pull/push workspace changes every few hours even when the app isn't on
/// screen, so notifications and the local workspace stay fresh.
///
/// Runs in the app's process. When the activity is alive its bridge is reused
/// (two open cores would clobber each other's in-memory workspace); when the
/// process was relaunched just for this job, a temporary bridge is opened and
/// closed. Skips entirely while the app is foregrounded — the 30s poll owns
/// syncing there.
internal class BackgroundSyncWorker(
    context: Context,
    params: WorkerParameters
) : Worker(context, params) {

    override fun doWork(): Result {
        // Accounts/sync are compiled out of release builds — no background sync.
        if (!BuildConfig.ACCOUNTS_ENABLED) return Result.success()
        if (MainActivity.isInForeground) return Result.success()
        val prefs = applicationContext.getSharedPreferences("knotq", Context.MODE_PRIVATE)
        val raw = prefs.getString(SYNC_SESSION_PREF, null) ?: return Result.success()
        val session = runCatching { JSONObject(raw) }.getOrNull() ?: return Result.success()
        if (!session.optBoolean("supports_sync", true)) return Result.success()
        val refreshToken = session.optString("refresh_token")
        if (refreshToken.isEmpty()) return Result.success()
        val apiBase = session.optString("api_base").trim().trimEnd('/')
        if (apiBase.isEmpty()) return Result.success()

        var bearerToken = session.optString("bearer_token")
        if (tokenNeedsRefresh(session.optString("expires_at"))) {
            when (refreshAndPersist(prefs, session, apiBase)) {
                is RefreshOutcome.Rotated -> {
                    bearerToken = session.optString("bearer_token")
                    if (!session.optBoolean("supports_sync", true)) return Result.success()
                }
                RefreshOutcome.SessionDead -> {
                    // The auth API explicitly rejected this refresh credential.
                    // Clear it so the app shows signed-out state on next launch.
                    prefs.edit().remove(SYNC_SESSION_PREF).apply()
                    return Result.success()
                }
                RefreshOutcome.Transient -> {
                    // Keep the session intact. The access token is near expiry, so
                    // avoid syncing with it and retry when refresh succeeds.
                    return Result.retry()
                }
            }
        }

        val shared = MainActivity.sharedBridge
        val bridge = shared ?: runCatching { RustBridge(applicationContext) }.getOrNull() ?: return Result.retry()
        return try {
            // Re-apply the FCM token so a device that registered (or rotated its
            // token) while backgrounded gets registered with the backend on this
            // sync. Idempotent — the core dedupes by token.
            PushRegistration.stored(applicationContext)?.let { PushRegistration.apply(bridge, it) }
            // One reactive auth retry. The proactive refresh above only fires when our
            // local expiry check says the token is near expiry; if the backend refuses
            // the bearer anyway (clock skew, an early server-side revoke, or a missed
            // key rotation), force a single refresh and try once more. sync_once throws
            // MobileException — NOT a RuntimeException — so the catch below never saw a
            // 401 and the job used to fail terminally (no retry). Bounded to one forced
            // refresh so a genuinely dead session can't loop.
            // A background run is usually here because a peer pushed (FCM wake /
            // onStop flush) — flag it so the core's idle-sync coalescer can't
            // skip the pull as "synced moments ago".
            runCatching { bridge.request(JSONObject().put("type", "note_remote_changed")) }
            var triedAuthRefresh = false
            var pulledRemoteChange = false
            while (true) {
                try {
                    pulledRemoteChange = bridge.request(
                        JSONObject()
                            .put("type", "sync_once")
                            .put("api_base", apiBase)
                            .put("bearer_token", bearerToken)
                    ).optBoolean("changed", false)
                    break
                } catch (error: MobileException) {
                    if (triedAuthRefresh || !isAuthRejection(error)) return Result.retry()
                    when (refreshAndPersist(prefs, session, apiBase)) {
                        is RefreshOutcome.Rotated -> {
                            if (!session.optBoolean("supports_sync", true)) return Result.success()
                            bearerToken = session.optString("bearer_token")
                            triedAuthRefresh = true
                        }
                        RefreshOutcome.SessionDead -> {
                            prefs.edit().remove(SYNC_SESSION_PREF).apply()
                            return Result.success()
                        }
                        RefreshOutcome.Transient -> return Result.retry()
                    }
                }
            }
            // Re-arm local alarms from the freshly-pulled schedule, on the SAME
            // bridge (refreshFromCore opens its own core, which would clobber this
            // one's in-memory state). This is what makes a peer's schedule change
            // surface as a notification on this device.
            runCatching {
                MobileNotificationScheduler.reschedule(
                    applicationContext,
                    bridge.requestArray(JSONObject().put("type", "pending_notifications"))
                )
                // And tear down banners for events that have since ended or
                // occurrences a peer completed (e.g. "mark done" on a desktop):
                // reschedule() only re-aims future alarms, so without this the
                // stale banner lingers in the tray until the app is next opened.
                MobileNotificationScheduler.clearStale(
                    applicationContext,
                    bridge.requestArray(JSONObject().put("type", "delivered_notifications_to_clear"))
                )
            }
            if (pulledRemoteChange) {
                // This pull mutated the (stopped) activity's own in-memory core, and
                // nothing else will tell it. The foreground poll on return doesn't
                // cover it either: the change is already applied, so that sync reports
                // changed=false and skips its loadSnapshot() — leaving the peer's edit
                // invisible until the app is restarted.
                MainActivity.notifyExternalStateChanged()
            }
            Result.success()
        } catch (error: RuntimeException) {
            Result.retry()
        } finally {
            if (shared == null) {
                runCatching { bridge.close() }
            }
        }
    }

    private sealed interface RefreshOutcome {
        class Rotated(val json: JSONObject) : RefreshOutcome
        object SessionDead : RefreshOutcome
        object Transient : RefreshOutcome
    }

    /// Refresh the access token and, on success, persist the rotated credentials
    /// into [session] and prefs immediately (the old refresh token is single-use,
    /// and the activity reloads this on its next onStart). Shared by the proactive
    /// near-expiry path and the reactive 401 path so both rotate at most once and
    /// store before the token is reused.
    private fun refreshAndPersist(
        prefs: SharedPreferences,
        session: JSONObject,
        apiBase: String
    ): RefreshOutcome {
        val outcome = refreshSession(apiBase, session.optString("refresh_token"))
        if (outcome is RefreshOutcome.Rotated) {
            session.put("bearer_token", outcome.json.optString("bearer_token"))
            session.put("expires_at", outcome.json.optString("expires_at"))
            session.put("refresh_token", outcome.json.optString("refresh_token"))
            session.put("refresh_expires_at", outcome.json.optString("refresh_expires_at"))
            session.put("supports_sync", outcome.json.optBoolean("supports_sync", true))
            prefs.edit().putString(SYNC_SESSION_PREF, session.toString()).apply()
        }
        return outcome
    }

    /// The backend refused the bearer token itself — an HTTP 401, which the auth
    /// middleware tags `unauthorized` and the core surfaces as that reason. Worth a
    /// forced refresh + one retry; other core errors are not.
    private fun isAuthRejection(error: MobileException): Boolean =
        error is MobileException.Core && error.reason.contains("unauthorized")

    private fun refreshSession(apiBase: String, refreshToken: String): RefreshOutcome {
        return try {
            val connection = (URL("$apiBase/v1/auth/refresh").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 10_000
                readTimeout = 10_000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
            val body = JSONObject().put("refresh_token", refreshToken).toString().toByteArray(Charsets.UTF_8)
            connection.outputStream.use { it.write(body) }
            val status = connection.responseCode
            when {
                isTerminalRefreshErrorCode(refreshApiErrorCode(connection)) -> RefreshOutcome.SessionDead
                status !in 200..299 -> RefreshOutcome.Transient
                else -> {
                    val raw = connection.inputStream.bufferedReader().use { it.readText() }
                    RefreshOutcome.Rotated(JSONObject(raw))
                }
            }
        } catch (error: Exception) {
            RefreshOutcome.Transient
        }
    }

    private fun tokenNeedsRefresh(expiresAt: String): Boolean {
        val expiry = runCatching { Instant.parse(expiresAt) }.getOrNull() ?: return true
        return expiry.isBefore(Instant.now().plusSeconds(120))
    }
}

/// Enqueue a one-off background sync to flush local edits (or pull a peer's
/// change) shortly after the app leaves the foreground. Unique + KEEP so a burst
/// of triggers — an FCM push, an onStop flush — coalesces into one run rather
/// than stacking redundant syncs.
internal fun enqueueOneTimeSync(context: Context) {
    if (!BuildConfig.ACCOUNTS_ENABLED) return
    runCatching {
        val request = OneTimeWorkRequest.Builder(BackgroundSyncWorker::class.java).build()
        WorkManager.getInstance(context)
            .enqueueUniqueWork("knotq-push-sync", ExistingWorkPolicy.KEEP, request)
    }
}
