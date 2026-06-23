package com.enigmadux.knotq

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters
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
            when (val refreshed = refreshSession(apiBase, refreshToken)) {
                is RefreshOutcome.Rotated -> {
                    // Persist immediately: the old refresh token is single-use,
                    // and the activity reloads this on its next onStart.
                    session.put("bearer_token", refreshed.json.optString("bearer_token"))
                    session.put("expires_at", refreshed.json.optString("expires_at"))
                    session.put("refresh_token", refreshed.json.optString("refresh_token"))
                    session.put("refresh_expires_at", refreshed.json.optString("refresh_expires_at"))
                    session.put("supports_sync", refreshed.json.optBoolean("supports_sync", true))
                    prefs.edit().putString(SYNC_SESSION_PREF, session.toString()).apply()
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
            bridge.request(
                JSONObject()
                    .put("type", "sync_once")
                    .put("api_base", apiBase)
                    .put("bearer_token", bearerToken)
            )
            // Re-arm local alarms from the freshly-pulled schedule, on the SAME
            // bridge (refreshFromCore opens its own core, which would clobber this
            // one's in-memory state). This is what makes a peer's schedule change
            // surface as a notification on this device.
            runCatching {
                MobileNotificationScheduler.reschedule(
                    applicationContext,
                    bridge.requestArray(JSONObject().put("type", "pending_notifications"))
                )
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
