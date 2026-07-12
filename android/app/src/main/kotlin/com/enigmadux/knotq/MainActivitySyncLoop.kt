package com.enigmadux.knotq

import android.app.Activity
import android.app.AlertDialog
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextPaint
import android.text.TextUtils
import android.text.TextWatcher
import android.util.Base64
import android.util.TypedValue
import android.view.ContextThemeWrapper
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Gravity
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.DecelerateInterpolator
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import android.widget.ArrayAdapter
import android.widget.AdapterView
import android.widget.CheckBox
import android.widget.DatePicker
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import android.widget.TimePicker
import android.widget.Toast
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.enigmadux.knotq.ffi.MobileException
import com.google.android.play.core.review.ReviewManagerFactory
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.TextStyle
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.UUID
import java.util.WeakHashMap
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal fun MainActivity.startSyncPolling() {
    syncPollHandler.removeCallbacks(syncPollRunnable)
    if (syncSession != null) {
        // Bootstrap once, then rely entirely on the socket while in the foreground:
        // NO periodic network poll. startWsNudge() drives prompt syncs from server
        // `changed` nudges (and an on-(re)connect catch-up), plus a slow fallback
        // that runs only while the socket is actually down. The 3h WorkManager job
        // (scheduleBackgroundSyncWork) is the background refresh.
        syncOnce()
        startWsSync()
        startWsNudge()
    }
}

/// Open the persistent sync WebSocket for the current session. While connected,
/// `sync_once`'s pull/push ride the socket. Idempotent in the core.
internal fun MainActivity.startWsSync() {
    val session = syncSession ?: return
    if (!session.supportsSync) return
    // runCatching also absorbs the case where `bridge` isn't initialized yet.
    runCatching {
        bridge.request(
            obj(
                "type" to "ws_start",
                "api_base" to session.apiBase,
                "bearer_token" to session.bearerToken
            )
        )
    }
}

internal fun MainActivity.stopWsSync() {
    runCatching { bridge.request(obj("type" to "ws_stop")) }
}

/// Background poller that reacts to a server `changed` nudge by syncing promptly
/// (the "live" receive path). Runs off the main thread because the core lock can be
/// held by an in-flight `sync_once` during network I/O; the actual `sync_once` is
/// dispatched back to the main thread (it owns `syncSession`/`syncInProgress`).
internal fun MainActivity.startWsNudge() {
    if (wsNudgeActive) return
    wsNudgeActive = true
    Thread {
        var secondsSinceFallbackPoll = 0
        while (wsNudgeActive) {
            try {
                Thread.sleep(1_000)
            } catch (_: InterruptedException) {
                break
            }
            if (!wsNudgeActive) break
            val pending = runCatching {
                bridge.request(obj("type" to "ws_pending_changed")).optBoolean("pending", false)
            }.getOrDefault(false)
            if (pending) {
                secondsSinceFallbackPoll = 0
                runOnUiThread { syncOnce() }
                continue
            }
            secondsSinceFallbackPoll += 1
            if (secondsSinceFallbackPoll >= 30) {
                secondsSinceFallbackPoll = 0
                // Foreground sync is socket-driven — only poll when the socket is
                // actually down (e.g. a network that blocks WS) so such a device
                // still converges. While connected, rely entirely on the nudges.
                val connected = runCatching {
                    bridge.request(obj("type" to "ws_connected")).optBoolean("connected", false)
                }.getOrDefault(false)
                if (!connected) runOnUiThread { syncOnce() }
            }
        }
    }.start()
}

internal fun MainActivity.stopWsNudge() {
    wsNudgeActive = false
}

/// Debounced sync after a local edit, matching desktop's local-change debounce:
/// a burst of edits coalesces into one push (SYNC_EDIT_DEBOUNCE_MS) instead of
/// syncing on every mutation. Leading-window — the first edit of a burst arms
/// the timer and later edits don't postpone it, so continuous typing still
/// pushes within the window (the 30s poll and the onStop flush are the
/// backstops; the in-progress guard handles overlap with the poll).
internal fun MainActivity.requestSyncSoon() {
    if (syncSession == null) return
    if (syncEditPending) return
    syncEditPending = true
    syncPollHandler.postDelayed(syncEditRunnable, SYNC_EDIT_DEBOUNCE_MS)
}

/// Periodic background refresh while signed in — the Android counterpart of
/// the iOS BGAppRefreshTask (3h cadence, network required).
internal fun MainActivity.scheduleBackgroundSyncWork() {
    val workManager = runCatching { WorkManager.getInstance(this) }.getOrNull() ?: return
    val session = syncSession
    if (session == null || !session.supportsSync) {
        workManager.cancelUniqueWork(BACKGROUND_SYNC_WORK)
        return
    }
    val request = PeriodicWorkRequest.Builder(BackgroundSyncWorker::class.java, 3, TimeUnit.HOURS)
        .setConstraints(
            Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()
        )
        .build()
    workManager.enqueueUniquePeriodicWork(BACKGROUND_SYNC_WORK, ExistingPeriodicWorkPolicy.KEEP, request)
}

internal fun MainActivity.cancelBackgroundSyncWork() {
    runCatching { WorkManager.getInstance(this).cancelUniqueWork(BACKGROUND_SYNC_WORK) }
}

internal fun MainActivity.syncOnce() {
    // The in-progress guard also serializes refresh: two concurrent refreshes
    // would replay the same single-use refresh token and trip the server's
    // reuse detection, revoking the session.
    if (syncInProgress) return
    val session = syncSession ?: return
    if (!session.supportsSync) return
    syncInProgress = true
    Thread {
        // Refresh the short-lived access token if near expiry (rotating +
        // persisting the new credentials). If refresh is temporarily unavailable,
        // skip this tick instead of syncing with an expired bearer token.
        var active = when (val refresh = refreshSyncSessionIfNeeded(session)) {
            is SyncRefreshResult.Ready -> refresh.session
            SyncRefreshResult.Deferred -> {
                runOnUiThread {
                    syncInProgress = false
                    syncOffline = true
                    render()
                }
                return@Thread
            }
            SyncRefreshResult.SessionDead -> {
                runOnUiThread {
                    syncInProgress = false
                    expireSyncSession()
                }
                return@Thread
            }
        }
        var expectedRefreshToken = session.refreshToken
        if (active != session) {
            val previousRefreshToken = expectedRefreshToken
            saveSyncSession(active)
            runOnUiThread {
                if (syncSession?.refreshToken == previousRefreshToken) {
                    syncSession = active
                    syncOffline = false
                    syncFailureNotified = false
                    saveSyncSession(active)
                }
            }
            expectedRefreshToken = active.refreshToken
        }
        if (!active.supportsSync) {
            runOnUiThread {
                syncInProgress = false
                if (syncSession?.refreshToken == expectedRefreshToken && syncSession != active) {
                    syncSession = active
                    syncOffline = false
                    syncFailureNotified = false
                    saveSyncSession(active)
                }
                scheduleBackgroundSyncWork()
                render()
            }
            return@Thread
        }

        var triedAuthRefresh = false
        var result: kotlin.Result<JSONObject>
        while (true) {
            result = runCatching {
                bridge.request(
                    obj(
                        "type" to "sync_once",
                        "api_base" to active.apiBase,
                        "bearer_token" to active.bearerToken
                    )
                )
            }
            val error = result.exceptionOrNull()
            if (error == null || triedAuthRefresh || !isAuthRejection(error)) break
            when (val refresh = refreshSyncSessionIfNeeded(active, force = true)) {
                is SyncRefreshResult.Ready -> {
                    expectedRefreshToken = active.refreshToken
                    active = refresh.session
                    saveSyncSession(active)
                    // Rebuild the socket: the current connection was authenticated
                    // with the token the backend just rejected.
                    runCatching { bridge.request(obj("type" to "ws_stop")) }
                    if (active.supportsSync) {
                        runCatching {
                            bridge.request(
                                obj(
                                    "type" to "ws_start",
                                    "api_base" to active.apiBase,
                                    "bearer_token" to active.bearerToken
                                )
                            )
                        }
                    }
                    if (!active.supportsSync) {
                        runOnUiThread {
                            syncInProgress = false
                            if (syncSession?.refreshToken == expectedRefreshToken && syncSession != active) {
                                syncSession = active
                                syncOffline = false
                                syncFailureNotified = false
                                saveSyncSession(active)
                            }
                            scheduleBackgroundSyncWork()
                            render()
                        }
                        return@Thread
                    }
                    triedAuthRefresh = true
                    continue
                }
                SyncRefreshResult.Deferred -> {
                    runOnUiThread {
                        syncInProgress = false
                        syncOffline = true
                        render()
                    }
                    return@Thread
                }
                SyncRefreshResult.SessionDead -> {
                    runOnUiThread {
                        syncInProgress = false
                        expireSyncSession()
                    }
                    return@Thread
                }
            }
        }

        runOnUiThread {
            syncInProgress = false
            if (syncSession?.refreshToken == expectedRefreshToken && syncSession != active) {
                syncSession = active
                syncOffline = false
                syncFailureNotified = false
                saveSyncSession(active)
                scheduleBackgroundSyncWork()
            }
            result.onSuccess { response ->
                syncFailureNotified = false
                syncOffline = false
                val changed = response.optBoolean("changed", false)
                if (changed) {
                    loadSnapshot()
                    rescheduleNotifications()
                    val active = activeEditor()
                    if (active != null && active.isFocused) {
                        // A remote change arrived while the user is editing. Don't
                        // full-render (it would reset the caret); instead reload just
                        // the focused editor with the MERGED content (caret kept). This
                        // shows the incoming edit AND rebases the editor so the next
                        // push-on-type flush (a full-document replace) merges instead of
                        // deleting the remote edit — the desktop->mobile drop. No-op if
                        // the merged text already matches (our own push echoing back).
                        reloadFocusedEditorFromSnapshot(active)
                    } else {
                        render()
                    }
                }
                val notice = response.optString("notice", "")
                if (notice.isNotEmpty()) {
                    toast(notice)
                }
            }.onFailure { error ->
                // Non-blocking like the iOS banner, and only on the first
                // failure so an offline session isn't toasted every poll. Transient
                // backend conditions (429 rate-limit, 5xx) are treated like being
                // offline so a brief throttle doesn't surface a scary error toast.
                if (isLikelyNetworkError(error) || isTransientSyncError(error)) {
                    syncOffline = true
                    render()
                    return@onFailure
                }
                if (!syncFailureNotified) {
                    syncFailureNotified = true
                    toast(error.message ?: "Sync failed")
                }
            }
        }
    }.start()
}

internal fun MainActivity.activeSyncSessionForAccountAction(session: SyncSession): SyncSession {
    return when (val refresh = refreshSyncSessionIfNeeded(session)) {
        is SyncRefreshResult.Ready -> {
            persistRotatedSyncSession(session, refresh.session)
            refresh.session
        }
        SyncRefreshResult.Deferred -> throw RuntimeException("Sync is offline. Try again when your connection is back.")
        SyncRefreshResult.SessionDead -> {
            runOnUiThread { expireSyncSession(showMessage = false) }
            throw RuntimeException(accountActionErrorMessage("unauthorized"))
        }
    }
}

internal fun MainActivity.persistRotatedSyncSession(previous: SyncSession, active: SyncSession) {
    if (active === previous || active.refreshToken == previous.refreshToken) return
    saveSyncSession(active)
    runOnUiThread {
        if (syncSession?.refreshToken == previous.refreshToken) {
            syncSession = active
            syncOffline = false
            syncFailureNotified = false
            scheduleBackgroundSyncWork()
            render()
        }
    }
}

internal fun MainActivity.expireSyncSession(showMessage: Boolean = true) {
    syncSession = null
    syncOffline = false
    syncEmailVerified = null
    resendVerificationCooldown = 0
    resendVerificationInProgress = false
    saveSyncSession(null)
    syncPollHandler.removeCallbacks(syncPollRunnable)
    syncPollHandler.removeCallbacks(syncEditRunnable)
    syncEditPending = false
    stopWsNudge()
    stopWsSync()
    cancelBackgroundSyncWork()
    if (showMessage) {
        showError("Sync session expired", "Please sign in again.")
    }
    render()
}

// Runs on a background thread (blocking HTTP). SessionDead is only returned
// when the refresh token is explicitly rejected by the auth endpoint. Deferred
// means the current token may be expired but the refresh could not be completed yet.
internal fun MainActivity.refreshSyncSessionIfNeeded(session: SyncSession, force: Boolean = false): SyncRefreshResult {
    val refreshToken = session.refreshToken
    if (refreshToken.isEmpty()) return SyncRefreshResult.Deferred
    if (!force && !tokenNeedsRefresh(session.expiresAt)) return SyncRefreshResult.Ready(session)
    try {
        val connection =
            (URL("${session.apiBase}/v1/auth/refresh").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 10_000
                readTimeout = 10_000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
        val body = JSONObject().put("refresh_token", refreshToken).toString().toByteArray(Charsets.UTF_8)
        connection.outputStream.use { it.write(body) }
        val status = connection.responseCode
        if (isTerminalRefreshErrorCode(refreshApiErrorCode(connection))) {
            return SyncRefreshResult.SessionDead
        }
        if (status !in 200..299) return SyncRefreshResult.Deferred
        val raw = connection.inputStream.bufferedReader().use { it.readText() }
        val json = JSONObject(raw)
        return SyncRefreshResult.Ready(session.copy(
            bearerToken = requiredString(json, "bearer_token"),
            expiresAt = requiredString(json, "expires_at"),
            refreshToken = requiredString(json, "refresh_token"),
            refreshExpiresAt = json.optString("refresh_expires_at").ifEmpty { null },
            supportsSync = json.optBoolean("supports_sync", true)
        ))
    } catch (error: Exception) {
        // Network/parse hiccup: keep the current token, retry next tick.
        return SyncRefreshResult.Deferred
    }
}

internal fun MainActivity.isLikelyNetworkError(error: Throwable): Boolean {
    var current: Throwable? = error
    while (current != null) {
        if (current is java.io.IOException) return true
        current = current.cause
    }
    val message = error.message.orEmpty().lowercase()
    return listOf(
        "network",
        "request failed",
        "timeout",
        "timed out",
        "unable to resolve",
        "failed to connect",
        "no address associated with hostname"
    ).any(message::contains)
}

// A 429 (rate-limited) or 5xx from the sync backend is transient: the next poll
// should simply retry. The core surfaces these as "sync backend rejected request:
// <code>" (a numeric status when the body wasn't a JSON error, e.g. a Cloudflare
// edge throttle, or "rate_limit_exceeded" from the Worker limiter). Treat them like
// being offline — quiet backoff — instead of toasting an error the user can't act on.
internal fun MainActivity.isTransientSyncError(error: Throwable): Boolean {
    val message = error.message.orEmpty().lowercase()
    if ("rate_limit" in message) return true
    return listOf("429", "500", "502", "503", "504").any { message.endsWith(": $it") }
}

internal fun MainActivity.isAuthRejection(error: Throwable): Boolean {
    var current: Throwable? = error
    while (current != null) {
        if (current is MobileException.Core && current.reason.contains("unauthorized")) return true
        current = current.cause
    }
    return error.message.orEmpty().contains("unauthorized", ignoreCase = true)
}

internal fun MainActivity.tokenNeedsRefresh(expiresAt: String): Boolean {
    val expiry = runCatching { java.time.Instant.parse(expiresAt) }.getOrNull() ?: return true
    return expiry.isBefore(java.time.Instant.now().plusSeconds(120))
}

internal fun MainActivity.requestSyncLoginStart(apiBase: String, email: String, password: String): SyncLoginStart {
    val json = httpJson(
        "$apiBase/v1/auth/login",
        "POST",
        JSONObject().put("email", email).put("password", password)
    )
    val challengeId = json.optString("challenge_id")
    if (challengeId.isNotEmpty()) {
        return SyncLoginStart(
            challenge = SyncLoginChallenge(
                apiBase = apiBase,
                email = email,
                challengeId = challengeId,
                devCode = json.optString("dev_code").ifEmpty { null }
            ),
            session = null
        )
    }
    return SyncLoginStart(challenge = null, session = parseSyncSession(json, apiBase))
}

internal fun MainActivity.parseSyncSession(json: JSONObject, apiBase: String): SyncSession =
    SyncSession(
        apiBase = apiBase,
        userId = requiredString(json, "user_id"),
        email = requiredString(json, "email"),
        supportsSync = json.optBoolean("supports_sync", true),
        bearerToken = requiredString(json, "bearer_token"),
        expiresAt = requiredString(json, "expires_at"),
        refreshToken = requiredString(json, "refresh_token"),
        refreshExpiresAt = json.optString("refresh_expires_at").ifEmpty { null }
    )

internal fun MainActivity.requiredString(json: JSONObject, key: String): String =
    json.optString(key).takeIf { it.isNotEmpty() }
        ?: throw RuntimeException("Sync API response missing $key.")

internal fun MainActivity.httpJson(
    urlString: String,
    method: String,
    body: JSONObject,
    bearerToken: String? = null,
    accountAction: Boolean = false,
    authorizeAction: Boolean = false
): JSONObject {
    val connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
        requestMethod = method
        connectTimeout = 10_000
        readTimeout = 10_000
        doInput = true
        doOutput = method != "GET"
        setRequestProperty("Content-Type", "application/json")
        bearerToken?.let { setRequestProperty("Authorization", "Bearer $it") }
    }
    if (method != "GET") {
        connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
    }
    val status = connection.responseCode
    val raw = if (status in 200..299) {
        connection.inputStream.bufferedReader().use { it.readText() }
    } else {
        connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
    }
    if (status !in 200..299) {
        val code = runCatching { JSONObject(raw).optString("code") }.getOrDefault("")
        throw RuntimeException(
            when {
                accountAction -> accountActionErrorMessage(code)
                authorizeAction -> authorizeErrorMessage(code)
                else -> syncErrorMessage(code)
            }
        )
    }
    return if (raw.isBlank()) JSONObject() else JSONObject(raw)
}

internal fun MainActivity.loadSyncSession(): SyncSession? {
    val raw = getSharedPreferences("knotq", Context.MODE_PRIVATE).getString(SYNC_SESSION_PREF, null)
        ?: return null
    return runCatching {
        val json = JSONObject(raw)
        SyncSession(
            apiBase = normalizeApiBase(json.optString("api_base")),
            userId = json.optString("user_id"),
            email = json.optString("email"),
            supportsSync = json.optBoolean("supports_sync", true),
            bearerToken = json.optString("bearer_token"),
            expiresAt = json.optString("expires_at"),
            refreshToken = json.optString("refresh_token").takeIf { it.isNotEmpty() }
                ?: throw RuntimeException("stored sync session missing refresh token"),
            refreshExpiresAt = json.optString("refresh_expires_at").ifEmpty { null }
        )
    }.getOrNull()
}

internal fun MainActivity.saveSyncSession(session: SyncSession?) {
    val prefs = getSharedPreferences("knotq", Context.MODE_PRIVATE).edit()
    if (session == null) {
        prefs.remove(SYNC_SESSION_PREF)
    } else {
        prefs.putString(
            SYNC_SESSION_PREF,
            JSONObject()
                .put("api_base", session.apiBase)
                .put("user_id", session.userId)
                .put("email", session.email)
                .put("supports_sync", session.supportsSync)
                .put("bearer_token", session.bearerToken)
                .put("expires_at", session.expiresAt)
                .put("refresh_token", session.refreshToken)
                .put("refresh_expires_at", session.refreshExpiresAt ?: JSONObject.NULL)
                .toString()
        )
    }
    prefs.apply()
}

internal fun MainActivity.normalizeApiBase(raw: String): String =
    raw.trim().trimEnd('/')

internal fun MainActivity.syncErrorMessage(code: String): String = when (code) {
    "account_exists" -> "An account already exists for that email."
    "invalid_email" -> "Enter a valid email address."
    "password_too_short" -> "Use a password with at least 12 characters."
    "unauthorized" -> "Email or password is incorrect."
    "password_too_long" -> "Password is too long."
    "invalid_code" -> "That code is incorrect."
    "code_expired", "invalid_or_expired_code" -> "That code has expired. Sign in again to get a new one."
    "too_many_attempts" -> "Too many incorrect codes. Sign in again to get a new one."
    else -> "Sync account request failed."
}

internal fun MainActivity.authorizeErrorMessage(code: String): String = when (code) {
    "invalid_authorization_code", "authorization_code_expired", "invalid_code_challenge" ->
        "Sign-in could not be completed. Please try signing in again."
    else -> "Sign in failed."
}

internal fun MainActivity.accountActionErrorMessage(code: String): String = when (code) {
    "unauthorized" -> "Your sync session expired. Sign in again, then retry."
    "delete_confirmation_mismatch" -> "Could not confirm the account. Please try again."
    "billing_api_not_configured" -> "Subscription cancellation is not configured yet."
    "cancel_in_app_store" -> "Manage this App Store subscription from your account subscriptions."
    "cancel_in_play_store" -> "Manage this subscription from your Google Play subscriptions."
    "resume_in_app_store" -> "Re-enable this subscription from your Apple account subscriptions."
    "resume_in_play_store" -> "Re-enable this subscription from your Google Play subscriptions."
    "no_active_subscription" -> "There's no active web subscription to change."
    "invalid_code" -> "That code is incorrect."
    "code_expired", "invalid_or_expired_code" -> "That code has expired. Start the deletion again to get a new one."
    "too_many_attempts" -> "Too many incorrect codes. Start the deletion again to get a new one."
    else -> "The request to the sync API failed."
}
